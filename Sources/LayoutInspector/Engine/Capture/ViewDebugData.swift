#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit
internal import LayoutInspectorAttributeGraph

/// Thin wrapper over one `attribute` dictionary of SwiftUI's encoding of `_ViewDebug.Data` (see `TreeEncoder`).
///
/// Shape (the same as in `_ViewDebug.serializedData` JSON):
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

    func at(_ path: String...) -> DebugAttribute? { at(path) }

    func at(_ path: [String]) -> DebugAttribute? {
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
    var origin: CGPoint?
    var size: CGSize?
    var children: [RawDebugNode]
    weak var parent: RawDebugNode?
    /// Inserted by `ComponentReconstruction` (not present in `_ViewDebug` data).
    var isSynthetic = false

    /// The node as SwiftUI recorded it. Its values are encoded only when something asks for them.
    private let source: _ViewDebug.Data?
    /// SwiftUI's own encoding of this node's properties, by `_ViewDebug.Property` raw value.
    private lazy var encoded: [Int: DebugAttribute] = source.map { data in
        let start = CACurrentMediaTime()
        defer { ViewDebugReader.noteEncoding(of: base, seconds: CACurrentMediaTime() - start) }
        isEncoded = true
        return ViewDebugReader.encodedProperties(of: data)
    } ?? [:]
    private var isEncoded = false
    /// `_ViewDebug.Property.value` as SwiftUI recorded it.
    private let rawValue: Any?
    private var parts: [String: DebugAttribute?] = [:]

    /// The view or modifier value (`_ViewDebug.Property.value`), as SwiftUI serialises it for Xcode.
    lazy var value: DebugAttribute? = encoded[1]

    /// `nil` when `data` is not shaped the way this reader knows.
    init?(data: _ViewDebug.Data) {
        guard let fields = ViewDebugReader.fields(of: data) else { return nil }
        source = data
        let properties = fields.properties
        rawValue = properties[.value]
        var children: [RawDebugNode] = []
        children.reserveCapacity(fields.children.count)
        for child in fields.children {
            guard let node = RawDebugNode(data: child) else { return nil }
            children.append(node)
        }
        self.children = children

        let type: Any.Type? = properties[.type].map { ($0 as? Any.Type) ?? Swift.type(of: $0) }
        if let type, let readable = ViewDebugReader.readableName(of: type) {
            typeName = ViewDebugReader.name(of: type)
            self.readable = readable
        } else {
            // No type property, or no AttributeGraph to name it: SwiftUI's encoding names it.
            let encoded = source.map(ViewDebugReader.encodedProperties(of:)) ?? [:]
            typeName = encoded[0]?.type ?? encoded[1]?.type ?? "?"
            readable = encoded[0]?.readableType ?? encoded[1]?.readableType ?? "?"
            self.encoded = encoded
            isEncoded = true
        }
        switch properties[.position] {
        case let p as CGPoint: origin = p.x.isFinite && p.y.isFinite ? p : nil
        case nil: origin = nil
        default: origin = encoded[3]?.point
        }
        switch properties[.size] {
        case let s as CGSize: size = s.width.isFinite && s.height.isFinite ? s : nil
        case nil: size = nil
        default: size = encoded[4]?.size
        }
        for c in children { c.parent = self }
    }

    /// A node of SwiftUI's own encoding of the whole tree (`_ViewDebug.Data` is `Encodable`), for data whose
    /// layout this reader does not know. Slower, the same result.
    init(encoded node: [String: Any]) {
        var attributes: [Int: DebugAttribute] = [:]
        for property in node["properties"] as? [[String: Any]] ?? [] {
            guard let id = (property["id"] as? NSNumber)?.intValue,
                  let attribute = property["attribute"] as? [String: Any] else { continue }
            attributes[id] = DebugAttribute(attribute)
        }
        source = nil
        rawValue = nil
        typeName = attributes[0]?.type ?? attributes[1]?.type ?? "?"
        readable = attributes[0]?.readableType ?? attributes[1]?.readableType ?? "?"
        origin = attributes[3]?.point
        size = attributes[4]?.size
        children = (node["children"] as? [[String: Any]] ?? []).map(RawDebugNode.init(encoded:))
        encoded = attributes
        isEncoded = true
        for c in children { c.parent = self }
    }

    init(syntheticType typeName: String, readable: String, children: [RawDebugNode], geometry: CGRect?) {
        self.typeName = typeName
        self.readable = readable
        self.source = nil
        self.rawValue = nil
        self.origin = geometry?.origin
        self.size = geometry?.size
        self.children = children
        self.isSynthetic = true
        for c in children { c.parent = self }
    }

    /// `value?.at(path)` without reflecting the rest of the value. The walk down `path` follows SwiftUI's own
    /// reflection (`ViewDebugReader.reflectedChildren`), and only the part at its end is encoded by SwiftUI, with
    /// the reflection depth it has inside the whole value. `nil` when that is not possible (the caller reads
    /// `value` then).
    func valuePart(_ path: [String]) -> DebugAttribute?? {
        if isEncoded { return .some(value?.at(path)) }
        let key = path.joined(separator: ".")
        if let cached = parts[key] { return .some(cached) }
        guard let source else { return .some(nil) }
        var current = ViewDebugReader.unwrapped(rawValue).map { (label: String?.none, value: $0) }
        var depth = ViewDebugReader.valueReflectionDepth
        for label in path {
            guard let node = current else { break }
            current = ViewDebugReader.reflectedChildren(of: node.value, depth: depth)?.first { $0.label == label }
            depth -= 1
        }
        return encode(current, level: path.count, key: key, template: source)
    }

    /// `value?.first(named: name, maxDepth: maxDepth)` without reflecting more of the value than the search
    /// visits: the same depth-first walk over the parts SwiftUI reflects, then only the match is encoded.
    func firstValuePart(named name: String, maxDepth: Int) -> DebugAttribute?? {
        if isEncoded { return .some(value?.first(named: name, maxDepth: maxDepth)) }
        let key = "first:\(name):\(maxDepth)"
        if let cached = parts[key] { return .some(cached) }
        guard let source else { return .some(nil) }
        func search(_ value: Any, level: Int, remaining: Int) -> (part: (label: String?, value: Any), level: Int)? {
            guard remaining > 0,
                  let children = ViewDebugReader.reflectedChildren(of: value, depth: ViewDebugReader.valueReflectionDepth - level)
            else { return nil }
            for child in children {
                if child.label == name { return (child, level + 1) }
                if let hit = search(child.value, level: level + 1, remaining: remaining - 1) { return hit }
            }
            return nil
        }
        let hit = ViewDebugReader.unwrapped(rawValue).flatMap { search($0, level: 0, remaining: maxDepth) }
        return encode(hit?.part, level: hit?.level ?? 0, key: key, template: source)
    }

    private func encode(_ part: (label: String?, value: Any)?, level: Int, key: String, template: _ViewDebug.Data) -> DebugAttribute?? {
        guard let part else {
            parts[key] = .some(nil)
            return .some(nil)
        }
        let start = CACurrentMediaTime()
        defer { ViewDebugReader.noteEncoding(of: base + "." + key, seconds: CACurrentMediaTime() - start) }
        guard let encoded = ViewDebugReader.encoded(part.value, label: part.label, level: level, template: template) else { return nil }
        parts[key] = .some(encoded)
        return .some(encoded)
    }

    /// The value, for reading later without keeping this node's subtree, its parents or the host's other data
    /// alive: an encoded value as it is, otherwise the node's own data without its children.
    func detachedValue() -> () -> DebugAttribute? {
        if isEncoded {
            let value = value
            return { value }
        }
        guard let source, let childless = ViewDebugReader.childless(source) else { return { [self] in value } }
        return { ViewDebugReader.encodedProperties(of: childless)[1] }
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

/// Direct access to `_ViewDebug.Data` (`_UIHostingView._viewDebugData()`), the data behind Xcode's view
/// debugger. SwiftUI serialises it into JSON by reflecting every value of every node, which costs far more than
/// reading it and is mostly thrown away: here the tree, the types and the geometry are read as they are, and a
/// node's values are encoded by SwiftUI itself only for the nodes that need them.
enum ViewDebugReader {
    struct Fields {
        let properties: [_ViewDebug.Property: Any]
        let children: [_ViewDebug.Data]
    }

    /// `_ViewDebug.Data` is `{ data: [Property: Any], childData: [Data] }`; `nil` if that ever changes.
    static func fields(of data: _ViewDebug.Data) -> Fields? {
        var properties: [_ViewDebug.Property: Any]?
        var children: [_ViewDebug.Data]?
        for child in Mirror(reflecting: data).children {
            switch child.label {
            case "data": properties = child.value as? [_ViewDebug.Property: Any]
            case "childData": children = child.value as? [_ViewDebug.Data]
            default: break
            }
        }
        guard let properties, let children else { return nil }
        return Fields(properties: properties, children: children)
    }

    /// The trees of `data`. When its layout is unknown, they come from SwiftUI's own encoding of the whole data
    /// (public, much slower) and one line is logged; `nil` when even that fails.
    static func trees(_ data: [_ViewDebug.Data], host: UIView) -> [RawDebugNode]? {
        var roots: [RawDebugNode] = []
        for root in data {
            guard let node = RawDebugNode(data: root) else { return encodedTrees(data, host: host) }
            roots.append(node)
        }
        return roots
    }

    private static func encodedTrees(_ data: [_ViewDebug.Data], host: UIView) -> [RawDebugNode]? {
        if !loggedUnknownLayout {
            loggedUnknownLayout = true
            NSLog("%@", "LayoutInspector: unknown _ViewDebug.Data layout on this iOS version, reading it the slow way")
        }
        let encoded = (try? TreeEncoder().encode(data)) as? [[String: Any]]
        ComponentReconstruction.log.append("\(TypeNames.shortClassName(host)): unknown _ViewDebug.Data layout, encoded \(encoded == nil ? "failed" : "ok")")
        return encoded?.map(RawDebugNode.init(encoded:))
    }

    private static var loggedUnknownLayout = false

    /// SwiftUI's encoding of one node's properties (not its children), by property raw value.
    static func encodedProperties(of data: _ViewDebug.Data) -> [Int: DebugAttribute] {
        var result: [Int: DebugAttribute] = [:]
        for property in (try? TreeEncoder().encodeProperties(of: data)) ?? [] {
            guard let id = (property["id"] as? NSNumber)?.intValue,
                  let attribute = property["attribute"] as? [String: Any] else { continue }
            result[id] = DebugAttribute(attribute)
        }
        return result
    }

    // MARK: - Part of a value

    /// Where `_ViewDebug.Data` keeps its two fields, checked against a real node once.
    private struct Layout { let properties: Int; let children: Int }
    private static var checkedLayout: Layout??

    private static func layout(checkedWith data: _ViewDebug.Data, _ fields: Fields) -> Layout? {
        if let checkedLayout { return checkedLayout }
        var found: Layout?
        if MemoryLayout<_ViewDebug.Data>.size == 2 * MemoryLayout<UInt>.size,
           MemoryLayout<[_ViewDebug.Property: Any]>.size == MemoryLayout<UInt>.size,
           MemoryLayout<[_ViewDebug.Data]>.size == MemoryLayout<UInt>.size {
            let words = withUnsafeBytes(of: data) { [$0.load(fromByteOffset: 0, as: UInt.self), $0.load(fromByteOffset: 8, as: UInt.self)] }
            let p = unsafeBitCast(fields.properties, to: UInt.self), c = unsafeBitCast(fields.children, to: UInt.self)
            if p != c, let pi = words.firstIndex(of: p), let ci = words.firstIndex(of: c), pi != ci {
                found = Layout(properties: pi * 8, children: ci * 8)
            }
        }
        checkedLayout = .some(found)
        return found
    }

    /// How deep SwiftUI reflects a node's value when it serialises it.
    static let valueReflectionDepth = 6

    /// The children SwiftUI reflects of a value at reflection depth `depth`, without their `nil` optionals; `nil`
    /// when SwiftUI writes the value as a leaf instead: at depth 0, for `Encodable` values, for `ModifiedContent`
    /// (its debug mirror is empty), for the values it converts and for values without children. Mirrors
    /// `_ViewDebug.Data.serializedAttribute` as reimplemented by OpenSwiftUI; the list of converted values is
    /// incomplete, and `LayoutInspector.partLookupMismatches(of:)` checks the result against the whole value.
    static func reflectedChildren(of value: Any, depth: Int) -> [(label: String?, value: Any)]? {
        guard depth > 0 else { return nil }
        let name = TypeNames.qualifiedName(of: type(of: value))
        if name.hasPrefix("SwiftUI.ModifiedContent<") || knownLeaves.contains(name) { return nil }
        // A conformance check costs a scan of every conformance in the app the first time for each type: the
        // generic containers a stack lookup walks through are known not to be `Encodable`.
        if !knownReflected.contains(where: name.hasPrefix), value is Encodable { return nil }
        let children = Mirror(reflecting: value).children
        guard !children.isEmpty else { return nil }
        return children.compactMap { child in unwrapped(child.value).map { (child.label, $0) } }
    }

    /// Written as values (`CustomViewDebugValueConvertible`, internal to SwiftUI), not reflected.
    private static let knownLeaves: Set<String> = ["SwiftUI.Edge.Set"]

    private static let knownReflected = [
        "SwiftUI.VStack<", "SwiftUI.HStack<", "SwiftUI.ZStack<", "SwiftUI._VariadicView.Tree<",
    ]

    /// A part of a node's value found `level` levels below it, encoded by SwiftUI exactly as it is inside the whole
    /// value: under `level` single-field wrappers, so that it gets the reflection depth it has there.
    static func encoded(_ value: Any, label: String?, level: Int, template data: _ViewDebug.Data) -> DebugAttribute? {
        var nested = value
        for _ in 0..<level { nested = Nest(value: nested) }
        guard case let .some(encoded) = Self.encoded(nested, template: data) else { return nil }
        var attribute = encoded
        for _ in 0..<level { attribute = attribute?["value"] }
        guard let attribute else { return nil }
        let raw = NSMutableDictionary(dictionary: attribute.raw)
        raw["name"] = label
        return DebugAttribute(raw as? [String: Any] ?? attribute.raw)
    }

    private struct Nest { let value: Any }

    /// SwiftUI's encoding of `value` as if it were the value of a childless node: the part of a node's value a
    /// capture needs, without reflecting the rest (a stack's value holds its whole content). `nil` when the
    /// node layout is unknown.
    /// `data` without its children.
    static func childless(_ data: _ViewDebug.Data) -> _ViewDebug.Data? {
        guard let fields = fields(of: data), let layout = layout(checkedWith: data, fields) else { return nil }
        var node = data
        withUnsafeMutableBytes(of: &node) { raw in
            raw.baseAddress!.advanced(by: layout.children).assumingMemoryBound(to: [_ViewDebug.Data].self).pointee = []
        }
        return node
    }

    private static func encoded(_ value: Any, template data: _ViewDebug.Data) -> DebugAttribute?? {
        guard let fields = fields(of: data), let layout = layout(checkedWith: data, fields) else { return nil }
        var node = data
        withUnsafeMutableBytes(of: &node) { raw in
            raw.baseAddress!.advanced(by: layout.properties)
                .assumingMemoryBound(to: [_ViewDebug.Property: Any].self).pointee = [.value: value]
            raw.baseAddress!.advanced(by: layout.children)
                .assumingMemoryBound(to: [_ViewDebug.Data].self).pointee = []
        }
        return .some(encodedProperties(of: node)[1])
    }

    /// SwiftUI unwraps one level of `Optional` before it encodes a value; `nil` for `.none`.
    static func unwrapped(_ value: Any?) -> Any? {
        guard let value else { return nil }
        guard TypeNames.qualifiedName(of: type(of: value)).hasPrefix("Swift.Optional<") else { return value }
        return Mirror(reflecting: value).children.first?.value
    }

    /// Every node of `host`'s trees with its type, geometry and encoded value, one per line (diagnostics).
    static func dump(of host: UIView) -> String? {
        var lines: [String]?
        SwiftUIGraphReader.inUpdate(of: host) { readDebugData in
            guard let trees = trees(readDebugData(), host: host) else { return }
            var out: [String] = []
            func visit(_ node: RawDebugNode, _ depth: Int) {
                out.append(dumpLine(depth: depth, type: node.typeName, readable: node.readable, origin: node.origin,
                                    size: node.size, value: node.value?.raw))
                node.children.forEach { visit($0, depth + 1) }
            }
            trees.forEach { visit($0, 0) }
            lines = out
        }
        return lines?.joined(separator: "\n")
    }

    static func dumpLine(depth: Int, type: String, readable: String, origin: CGPoint?, size: CGSize?, value: [String: Any]?) -> String {
        let json = value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
        return String(repeating: " ", count: depth) + "\(type) | \(readable) | \(origin.map { "\($0.x),\($0.y)" } ?? "nil") | "
            + "\(size.map { "\($0.width)x\($0.height)" } ?? "nil") | \(json)"
    }

    /// Time spent encoding node values in the current capture, by node base type (diagnostics).
    static var encodingTimes: [String: (count: Int, seconds: Double)] = [:]

    static func noteEncoding(of base: String, seconds: Double) {
        let entry = encodingTimes[base] ?? (0, 0)
        encodingTimes[base] = (entry.count + 1, entry.seconds + seconds)
    }

    /// The most expensive encodings of the current capture, for `LayoutCapture.lastTimings`.
    static var encodingSummary: [String] {
        encodingTimes.sorted { $0.value.seconds > $1.value.seconds }.prefix(6)
            .map { "encode[\($0.key)] \(Int($0.value.seconds * 1000)) ms ×\($0.value.count)" }
    }

    private static var readableNames: [ObjectIdentifier: String] = [:]

    /// What SwiftUI writes to `type`.
    static func name(of type: Any.Type) -> String { TypeNames.qualifiedName(of: type) }

    /// AttributeGraph's type description, which is what SwiftUI writes to `readableType`.
    static func readableName(of type: Any.Type) -> String? {
        let key = ObjectIdentifier(type)
        if let cached = readableNames[key] { return cached }
        guard let description = LIAGTypeDescription(unsafeBitCast(type, to: UnsafeRawPointer.self)) else { return nil }
        let object = Unmanaged<CFTypeRef>.fromOpaque(description).takeUnretainedValue()
        guard CFGetTypeID(object) == CFStringGetTypeID() else { return nil }
        let name = unsafeDowncast(object, to: CFString.self) as String
        readableNames[key] = name
        return name
    }
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
        base(of: name(of: type(of: object)))
    }

    private static var qualifiedNames: [ObjectIdentifier: String] = [:]
    private static var names: [ObjectIdentifier: String] = [:]

    /// `String(reflecting: type)` without its cost. Printing a metatype first asks whether it conforms to
    /// `CustomDebugStringConvertible` and the like, and a conformance check of a type the runtime has not seen yet
    /// scans every conformance record of every loaded image: milliseconds per type in a large app, seconds per
    /// capture. `_typeName` prints the same name directly.
    static func qualifiedName(of type: Any.Type) -> String {
        let key = ObjectIdentifier(type)
        if let cached = qualifiedNames[key] { return cached }
        let name = _typeName(type, qualified: true)
        qualifiedNames[key] = name
        return name
    }

    /// `String(describing: type)`, see `qualifiedName(of:)`.
    static func name(of type: Any.Type) -> String {
        let key = ObjectIdentifier(type)
        if let cached = names[key] { return cached }
        let name = _typeName(type, qualified: false)
        names[key] = name
        return name
    }
}

#endif
