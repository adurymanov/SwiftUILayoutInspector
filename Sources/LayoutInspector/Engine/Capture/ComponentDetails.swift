#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit

/// What the components list shows about one component beyond its frame: the view's properties as its parent built
/// them, its `@State`, `@Binding`, `@Environment` and observed objects, the environment of its window and the fonts
/// of its texts. Read on demand, never during a capture.
struct ComponentDetails {
    struct Property: Equatable {
        enum Kind: String {
            case value, state, binding, environment, observed
        }

        let name: String
        let kind: Kind
        let type: String
        /// `nil` when SwiftUI keeps the value where it can't be read (`@State`, `@Environment`).
        let value: String?

        var line: String {
            let prefix = kind == .value ? "" : "@\(kind.label) "
            return "\(prefix)\(name): \(type)" + (value.map { " = \($0)" } ?? "")
        }
    }

    var properties: [Property] = []
    /// Why there are no properties: the view couldn't be told apart from others of its type, or the graph is out of
    /// reach on this iOS version.
    var note: String?
    /// The environment of the hosting view, as its traits give it.
    var environment: [(name: String, value: String)] = []
    /// Fonts of the texts inside, the most used first.
    var fonts: [(font: String, count: Int)] = []

    static func read(_ node: InspectorNode, match: ComponentGraph.Match?) -> ComponentDetails {
        var details = ComponentDetails()
        if let match, match.isExact, let view = match.views.first, let value = ComponentGraph.value(of: view) {
            details.properties = properties(of: value)
        } else if let match, !match.isExact {
            details.note = "One of \(match.views.count) views of this type that can't be told apart: properties are not shown."
        } else {
            details.note = "The view graph can't be read on this iOS version: properties are not shown."
        }
        details.environment = environment(of: node)
        details.fonts = fonts(in: node)
        return details
    }

    // MARK: - Properties

    static func properties(of value: Any) -> [Property] {
        Mirror(reflecting: value).children.compactMap { child in
            guard let label = child.label, !label.hasPrefix("_$") else { return nil }
            let type = AttributeGraphTree.readable(String(reflecting: Swift.type(of: child.value)))
            let base = TypeNames.base(of: type)
            let argument = TypeNames.genericArguments(of: type).first ?? type
            let name = String(label.drop { $0 == "_" })
            switch base {
            case "State", "LazyState":
                return Property(name: name, kind: .state, type: argument, value: nil)
            case "Binding":
                let current = Mirror(reflecting: child.value).children.first { $0.label == "_value" }?.value
                return Property(name: name, kind: .binding, type: argument, value: current.map(describe))
            case "Environment":
                return Property(name: name, kind: .environment, type: argument, value: nil)
            case "ObservedObject", "StateObject", "EnvironmentObject", "Bindable":
                let object = Mirror(reflecting: child.value).children.first.map(\.value)
                return Property(name: name, kind: .observed, type: argument, value: object.map(describe))
            default:
                return Property(name: label, kind: .value, type: type, value: describe(child.value))
            }
        }
    }

    /// One line: strings quoted, objects and structs as `Type(a: 1, b: 2)` one level deep, at most 160 characters.
    static func describe(_ value: Any) -> String {
        let text: String
        if let string = value as? String {
            text = "\"\(string)\""
        } else if value is CustomStringConvertible, Mirror(reflecting: value).children.isEmpty || value is any Numeric {
            text = String(describing: value)
        } else {
            let mirror = Mirror(reflecting: value)
            let fields = mirror.children.compactMap { child -> String? in
                guard let label = child.label, !label.hasPrefix("_$") else { return nil }
                let name = label.hasPrefix("_") && mirror.displayStyle == .class ? String(label.dropFirst()) : label
                return "\(name): \(shortValue(child.value))"
            }
            let type = AttributeGraphTree.readable(String(reflecting: Swift.type(of: value)))
            text = mirror.displayStyle == .optional ? (mirror.children.first.map { describe($0.value) } ?? "nil")
                : mirror.displayStyle == .enum ? String(describing: value)
                : "\(type)(\(fields.joined(separator: ", ")))"
        }
        return text.count > 160 ? String(text.prefix(159)) + "…" : text
    }

    private static func shortValue(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string.prefix(40))\"" }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .collection { return "[\(mirror.children.count) items]" }
        if mirror.displayStyle == .optional { return mirror.children.first.map { shortValue($0.value) } ?? "nil" }
        if mirror.children.isEmpty || value is any Numeric { return String(describing: value).prefix(40).description }
        return AttributeGraphTree.readable(String(reflecting: type(of: value))) + "(…)"
    }

    // MARK: - Environment

    /// The values layout depends on, from the traits of the view the component is in. `.environment(…)` set inside
    /// the screen is not included: SwiftUI records it only with `SWIFTUI_VIEW_DEBUG`'s environment bit, which costs
    /// every capture 8–14 %.
    static func environment(of node: InspectorNode) -> [(name: String, value: String)] {
        guard let view = node.anchor.view else { return [] }
        let traits = view.traitCollection
        var result: [(String, String)] = [
            ("colorScheme", traits.userInterfaceStyle == .dark ? "dark" : "light"),
            ("dynamicTypeSize", DynamicTypeSize(traits.preferredContentSizeCategory).map { "\($0)" } ?? traits.preferredContentSizeCategory.rawValue),
            ("layoutDirection", traits.layoutDirection == .rightToLeft ? "rightToLeft" : "leftToRight"),
            ("legibilityWeight", traits.legibilityWeight == .bold ? "bold" : "regular"),
            ("horizontalSizeClass", traits.horizontalSizeClass == .compact ? "compact" : traits.horizontalSizeClass == .regular ? "regular" : "unspecified"),
            ("verticalSizeClass", traits.verticalSizeClass == .compact ? "compact" : traits.verticalSizeClass == .regular ? "regular" : "unspecified"),
            ("displayScale", traits.displayScale.pt),
            ("locale", Locale.current.identifier),
        ]
        if traits.accessibilityContrast == .high { result.append(("colorSchemeContrast", "increased")) }
        return result
    }

    static func fonts(in node: InspectorNode) -> [(font: String, count: Int)] {
        var counts: [String: Int] = [:]
        node.forEach { if let font = $0.info.text?.font { counts[font.displayName, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: - Text

    func text(for node: InspectorNode, renders: RenderCounts.Entry?) -> String {
        var lines = ["\(node.title)  \(AttributeGraphTree.readable(node.typeName))", "frame \(node.frame.frameLabel)"]
        if let renders { lines.append("renders \(renders.label)") }
        if let note { lines.append(note) }
        if !properties.isEmpty { lines.append("properties:"); lines += properties.map { "  " + $0.line } }
        if !fonts.isEmpty { lines.append("fonts: " + fonts.map { "\($0.font) ×\($0.count)" }.joined(separator: ", ")) }
        if !environment.isEmpty { lines.append("environment: " + environment.map { "\($0.name) \($0.value)" }.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

extension ComponentDetails.Property.Kind {
    var label: String {
        switch self {
        case .value: ""
        case .state: "State"
        case .binding: "Binding"
        case .environment: "Environment"
        case .observed: "Observed"
        }
    }
}

extension CGRect {
    var frameLabel: String { isNull ? "–" : "\(minX.pt),\(minY.pt) \(sizeLabel)" }
}

#endif
