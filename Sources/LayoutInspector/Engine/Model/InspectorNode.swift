#if LayoutInspectorEngine && os(iOS)
import UIKit

/// What a node in the inspected hierarchy represents.
public enum NodeKind: String, CaseIterable, Sendable {
    // Containers
    case host            // a `_UIHostingView` root (screen, list cell, toolbar…)
    case component       // a custom `View` type declared in the app (ProfileHeader, PriceRow…)
    case customModifier  // a custom `ViewModifier` declared in the app
    case stack           // VStack / HStack / ZStack / Lazy*Stack / Grid / custom Layout
    case scroll          // ScrollView
    case list            // List / Form
    case control         // Button, Toggle, TextField, Picker…
    // Leaves
    case text, image, shape, color, spacer, divider, platform
    // Layout modifiers (SwiftUI "constraints")
    case padding, frame, flexFrame, fixedSize, aspectRatio, offset, layoutPriority, ignoresSafeArea
    // Render tree (UIKit)
    case uikitView
    case renderLayer

    public var isLayoutModifier: Bool {
        switch self {
        case .padding, .frame, .flexFrame, .fixedSize, .aspectRatio, .offset, .layoutPriority, .ignoresSafeArea: true
        default: false
        }
    }

    public var isContent: Bool {
        switch self {
        case .text, .image, .shape, .color, .divider, .platform, .control: true
        default: false
        }
    }
}

/// A rect expressed in the coordinate space of some live `UIView`.
/// SwiftUI reports geometry in the space of its hosting view (or of the scroll content),
/// so we keep the anchor and resolve it lazily – that way the overlay follows scrolling for free.
public struct NodeAnchor {
    public weak var view: UIView?
    public var rect: CGRect

    public init(view: UIView?, rect: CGRect) {
        self.view = view
        self.rect = rect
    }

    public func resolve(in space: UIView) -> CGRect? {
        guard let view, view.window != nil || view === space else { return nil }
        return view.convert(rect, to: space)
    }
}

public struct EdgeValues: Equatable, Sendable {
    public var top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat
    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public static let zero = EdgeValues()
    public var isZero: Bool { abs(top) < 0.01 && abs(leading) < 0.01 && abs(bottom) < 0.01 && abs(trailing) < 0.01 }
    public var compact: String {
        let v = [top, leading, bottom, trailing]
        if Set(v).count == 1 { return v[0].pt }
        if top == bottom && leading == trailing { return "v \(top.pt) · h \(leading.pt)" }
        return "t \(top.pt) · l \(leading.pt) · b \(bottom.pt) · r \(trailing.pt)"
    }
}

public struct PaddingInfo {
    /// Insets as written in code. `nil` means `.padding()` with system default.
    public var declared: EdgeValues?
    public var edges: [String]
    /// Insets measured from the real outer/inner geometry.
    public var measured: EdgeValues = .zero
    public var inner: NodeAnchor?
    public var isSystem: Bool = false
}

public struct FrameRule {
    public var width: CGFloat?, height: CGFloat?
    public var minWidth: CGFloat?, idealWidth: CGFloat?, maxWidth: CGFloat?
    public var minHeight: CGFloat?, idealHeight: CGFloat?, maxHeight: CGFloat?
    public var alignment: String?
    public var isFlexible: Bool

    public var code: String {
        var parts: [String] = []
        func add(_ name: String, _ v: CGFloat?) { if let v { parts.append("\(name): \(v.ptOrInf)") } }
        add("width", width); add("height", height)
        add("minWidth", minWidth); add("idealWidth", idealWidth); add("maxWidth", maxWidth)
        add("minHeight", minHeight); add("idealHeight", idealHeight); add("maxHeight", maxHeight)
        if let alignment, alignment != "center" { parts.append("alignment: .\(alignment)") }
        return ".frame(\(parts.joined(separator: ", ")))"
    }
}

public struct StackInfo {
    public enum Axis: String { case vertical, horizontal, depth, grid }
    public var axis: Axis
    public var name: String
    public var alignment: String?
    /// Spacing as written in code. `nil` = system default (adaptive).
    public var spacing: CGFloat?
}

public struct FontInfo: Equatable {
    public var family: String
    public var postScriptName: String
    public var size: CGFloat
    public var weight: String
    public var textStyle: String?
    public var lineHeight: CGFloat
    public var isDynamicType: Bool { textStyle != nil }

    public var displayName: String {
        if let textStyle { return "\(textStyle) \(size.pt)pt \(weight)" }
        return "\(family) \(size.pt)pt \(weight)"
    }
}

public struct TextInfo {
    public var string: String
    public var font: FontInfo?
    public var colorHex: String?
    public var alignment: String?
    public var lineCount: Int?
    public var isTruncated: Bool = false
    public var firstBaseline: CGFloat?
    public var kerning: CGFloat?
    public var runCount: Int = 1
}

public struct ImageInfo {
    public var name: String
    public var isSymbol: Bool
    public var naturalSize: CGSize?
}

public struct ConstraintInfo {
    public var text: String
    public var firstAttribute: NSLayoutConstraint.Attribute
    public var secondAttribute: NSLayoutConstraint.Attribute
    public var first: NodeAnchor
    public var second: NodeAnchor?
    public var constant: CGFloat
    public var relation: NSLayoutConstraint.Relation
    public var priority: Float
}

public struct UIKitInfo {
    public var className: String
    public var font: FontInfo?
    public var text: String?
    public var textColorHex: String?
    public var constraints: [ConstraintInfo] = []
    public var contentInset: UIEdgeInsets?
    public var layoutMargins: UIEdgeInsets?
    public var intrinsicSize: CGSize?
    public var hugging: (h: Float, v: Float)?
    public var compression: (h: Float, v: Float)?
    public var usesAutoLayout: Bool = false
    public var hasAmbiguousLayout: Bool = false
    public var isAppView: Bool = false
    public var stackSpacing: CGFloat?
    public var stackAxis: NSLayoutConstraint.Axis?
    public var arrangedSubviews: [NodeAnchor] = []
}

/// Everything we know about a node beyond its geometry.
public struct NodeInfo {
    public var padding: PaddingInfo?
    public var frameRule: FrameRule?
    public var stack: StackInfo?
    public var text: TextInfo?
    public var image: ImageInfo?
    public var shapeName: String?
    public var fill: String?
    public var fixedSize: (horizontal: Bool, vertical: Bool)?
    public var layoutPriority: Double?
    public var spacerMinLength: CGFloat?
    public var aspectRatio: (ratio: CGFloat?, contentMode: String)?
    public var offset: CGSize?
    public var decorations: [String] = []
    public var uikit: UIKitInfo?
    public var isInternal: Bool = false
    /// Flattened raw values from the SwiftUI debug graph (shown in the details panel).
    public var raw: [(String, String)] = []

    public init() {}
}

/// One element of a captured hierarchy: a SwiftUI view or layout modifier, or a UIKit view / render layer.
public final class InspectorNode: Identifiable {
    /// Unique within the process; changes on every capture of the node.
    public let id: Int
    public let kind: NodeKind
    /// Type name for components and stacks (`ProfileHeader`, `VStack`), the modifier (`.padding`) or the primitive (`Text`).
    public internal(set) var title: String
    /// Values: `"(16)"` for a padding, `"spacing 8 · .leading"` for a stack, the string of a `Text`.
    public internal(set) var detail: String?
    /// Full Swift type name.
    public let typeName: String
    public internal(set) var anchor: NodeAnchor
    public internal(set) var info: NodeInfo
    public internal(set) var children: [InspectorNode] = []
    public internal(set) weak var parent: InspectorNode?
    /// Frame in the overlay coordinate space. Updated by `InspectorCapture.resolveFrames(in:)`.
    public internal(set) var frame: CGRect = .null

    init(id: Int, kind: NodeKind, title: String, detail: String? = nil, typeName: String, anchor: NodeAnchor, info: NodeInfo = NodeInfo()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.typeName = typeName
        self.anchor = anchor
        self.info = info
    }

    func add(_ child: InspectorNode) {
        child.parent = self
        children.append(child)
    }

    public var isVisible: Bool { !frame.isNull && frame.width >= 0 && frame.height >= 0 }

    public var depth: Int {
        var d = 0, p = parent
        while let n = p { d += 1; p = n.parent }
        return d
    }

    public var path: [InspectorNode] {
        var result: [InspectorNode] = [self]
        var p = parent
        while let n = p { result.insert(n, at: 0); p = n.parent }
        return result
    }

    public func forEach(_ body: (InspectorNode) -> Void) {
        body(self)
        for child in children { child.forEach(body) }
    }

    public func first(where predicate: (InspectorNode) -> Bool) -> InspectorNode? {
        if predicate(self) { return self }
        for child in children { if let hit = child.first(where: predicate) { return hit } }
        return nil
    }

    /// Short label used in tags and in the tree.
    public var label: String {
        if let detail, !detail.isEmpty { return "\(title) \(detail)" }
        return title
    }
}

extension CGFloat {
    /// "16", "16.5", "0.33"
    var pt: String {
        if self.isInfinite { return self > 0 ? "∞" : "-∞" }
        let rounded = (self * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        if (rounded * 10) == (rounded * 10).rounded() { return String(format: "%.1f", Double(rounded)) }
        return String(format: "%.2f", Double(rounded))
    }

    var ptOrInf: String { isInfinite ? ".infinity" : pt }
}

extension CGRect {
    var sizeLabel: String { "\(width.pt)×\(height.pt)" }
}

#endif
