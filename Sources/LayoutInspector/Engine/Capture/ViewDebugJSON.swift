#if LayoutInspectorEngine && os(iOS)
import UIKit

/// Thin wrapper over one `attribute` dictionary of `_ViewDebug.Data` JSON.
///
/// Shape (produced by `_ViewDebug.serializedData`):
/// ```
/// { "type": "SwiftUI._PaddingLayout", "readableType": "_PaddingLayout", "name": "insets",
///   "value": <scalar | array>, "subattributes": [ ...same shape... ] }
/// ```
struct DebugAttribute {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    var type: String { raw["type"] as? String ?? "" }
    var readableType: String { raw["readableType"] as? String ?? "" }
    var name: String? { raw["name"] as? String }
    var value: Any? { raw["value"] }

    var subattributes: [DebugAttribute] {
        (raw["subattributes"] as? [[String: Any]])?.map(DebugAttribute.init) ?? []
    }

    subscript(_ name: String) -> DebugAttribute? {
        subattributes.first { $0.name == name }
    }

    func at(_ path: String...) -> DebugAttribute? {
        var current: DebugAttribute? = self
        for component in path { current = current?[component] }
        return current
    }

    var number: CGFloat? {
        switch value {
        case let n as NSNumber: return CGFloat(truncating: n)
        case let s as String:
            if s == "inf" { return .infinity }
            if s == "-inf" { return -.infinity }
            if s == "nan" { return nil }
            return Double(s).map { CGFloat($0) }
        default: return nil
        }
    }

    var string: String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    var bool: Bool? { (value as? NSNumber)?.boolValue }

    var point: CGPoint? {
        guard let a = value as? [NSNumber], a.count == 2 else { return nil }
        return CGPoint(x: CGFloat(truncating: a[0]), y: CGFloat(truncating: a[1]))
    }

    var size: CGSize? {
        guard let a = value as? [NSNumber], a.count == 2 else { return nil }
        return CGSize(width: CGFloat(truncating: a[0]), height: CGFloat(truncating: a[1]))
    }

    /// Depth-first search through sub-attributes.
    func first(maxDepth: Int = 12, where predicate: (DebugAttribute) -> Bool) -> DebugAttribute? {
        if predicate(self) { return self }
        guard maxDepth > 0 else { return nil }
        for sub in subattributes {
            if let hit = sub.first(maxDepth: maxDepth - 1, where: predicate) { return hit }
        }
        return nil
    }

    func first(named name: String, maxDepth: Int = 12) -> DebugAttribute? {
        first(maxDepth: maxDepth) { $0.name == name }
    }

    /// Flattens scalar leaves to `path = value` pairs for the details panel.
    func flatten(prefix: String = "", into result: inout [(String, String)], limit: Int = 40, depth: Int = 0) {
        guard result.count < limit, depth < 6 else { return }
        let key = prefix.isEmpty ? (name ?? "") : (name.map { "\(prefix).\($0)" } ?? prefix)
        if let v = value {
            var text: String
            switch v {
            case let s as String: text = s
            case let n as NSNumber: text = n.stringValue
            case let a as [Any]: text = "[" + a.map { "\($0)" }.joined(separator: ", ") + "]"
            default: text = "\(v)"
            }
            if text.count > 140 { text = String(text.prefix(140)) + "…" }
            if !key.isEmpty { result.append((key, text)) }
        }
        for sub in subattributes { sub.flatten(prefix: key, into: &result, limit: limit, depth: depth + 1) }
    }
}

/// One node of the raw SwiftUI debug tree.
final class RawDebugNode {
    let typeName: String
    let readable: String
    let value: DebugAttribute?
    var origin: CGPoint?
    var size: CGSize?
    var children: [RawDebugNode]
    weak var parent: RawDebugNode?
    /// Inserted by `ComponentReconstruction` (not present in `_ViewDebug` data).
    var isSynthetic = false

    init(json: [String: Any]) {
        var typeAttr: DebugAttribute?
        var valueAttr: DebugAttribute?
        var origin: CGPoint?
        var size: CGSize?
        for property in json["properties"] as? [[String: Any]] ?? [] {
            guard let id = (property["id"] as? NSNumber)?.intValue,
                  let attribute = property["attribute"] as? [String: Any] else { continue }
            let attr = DebugAttribute(attribute)
            switch id {
            case 0: typeAttr = attr      // _ViewDebug.Property.type
            case 1: valueAttr = attr     // .value
            case 3: origin = attr.point  // .position
            case 4: size = attr.size     // .size
            default: break
            }
        }
        typeName = typeAttr?.type ?? valueAttr?.type ?? "?"
        readable = typeAttr?.readableType ?? valueAttr?.readableType ?? "?"
        value = valueAttr
        self.origin = origin
        self.size = size
        children = (json["children"] as? [[String: Any]] ?? []).map(RawDebugNode.init(json:))
        for c in children { c.parent = self }
    }

    init(syntheticType typeName: String, readable: String, children: [RawDebugNode], geometry: CGRect?) {
        self.typeName = typeName
        self.readable = readable
        self.value = nil
        self.origin = geometry?.origin
        self.size = geometry?.size
        self.children = children
        self.isSynthetic = true
        for c in children { c.parent = self }
    }

    var hasGeometry: Bool { origin != nil && size != nil }

    var geometry: CGRect? {
        guard let origin, let size else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// First geometry found going down the tree (the box this subtree occupies).
    var firstGeometry: CGRect? {
        if let g = geometry { return g }
        for c in children { if let g = c.firstGeometry { return g } }
        return nil
    }

    func forEach(_ body: (RawDebugNode) -> Void) {
        body(self)
        for c in children { c.forEach(body) }
    }

    /// `VStack<TupleView<…>>` -> `VStack`
    lazy var base: String = TypeNames.base(of: readable)

    /// `SwiftUI._PaddingLayout` -> `SwiftUI`
    lazy var module: String = TypeNames.module(of: typeName)

    lazy var genericArguments: [String] = TypeNames.genericArguments(of: readable)
}

enum TypeNames {
    static let systemModules: Set<String> = [
        "SwiftUI", "SwiftUICore", "Swift", "UIKit", "Foundation", "_Concurrency", "Combine",
        "MapKit", "Charts", "AVKit", "__C", "CoreGraphics", "LayoutInspector", "Observation", "?",
    ]

    static func base(of readable: String) -> String {
        if let i = readable.firstIndex(of: "<") { return String(readable[..<i]) }
        return readable
    }

    static func module(of typeName: String) -> String {
        let baseName = base(of: typeName)
        if let i = baseName.firstIndex(of: ".") { return String(baseName[..<i]) }
        return baseName
    }

    /// Top-level generic arguments: `A<B<C>, D>` -> ["B<C>", "D"]
    static func genericArguments(of readable: String) -> [String] {
        guard let open = readable.firstIndex(of: "<"), readable.hasSuffix(">") else { return [] }
        let inner = readable[readable.index(after: open)..<readable.index(before: readable.endIndex)]
        var result: [String] = []
        var depth = 0
        var current = ""
        for ch in inner {
            switch ch {
            case "<", "(", "{", "[": depth += 1; current.append(ch)
            case ">", ")", "}", "]": depth -= 1; current.append(ch)
            case "," where depth == 0:
                result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }

    /// "InspectorDemo.(unknown context at $1c7).ProfileContent" -> "ProfileContent"
    static func shortName(of typeName: String) -> String {
        let base = base(of: typeName)
        if let range = base.range(of: ").", options: .backwards) { return String(base[range.upperBound...]) }
        if let dot = base.lastIndex(of: ".") { return String(base[base.index(after: dot)...]) }
        return base
    }

    static func isAppType(_ typeName: String) -> Bool {
        let module = module(of: typeName)
        return !systemModules.contains(module) && !module.hasPrefix("(") && !module.isEmpty
    }

    /// Unwraps `ModifiedContent` and returns `Base<FirstArgBase>` of the innermost content – a cheap
    /// signature of what a container/modifier actually wraps.
    static func contentSignature(of readable: String) -> String {
        var current = readable
        while base(of: current) == "ModifiedContent", let first = genericArguments(of: current).first {
            current = first
        }
        let args = genericArguments(of: current)
        guard let first = args.first else { return base(of: current) }
        return base(of: current) + "<" + base(of: first) + ">"
    }

    /// Removes generic noise for display: `UIKitPlatformViewHost<…>` -> `UIKitPlatformViewHost`.
    static func shortClassName(_ object: AnyObject) -> String {
        base(of: String(describing: type(of: object)))
    }
}

#endif
