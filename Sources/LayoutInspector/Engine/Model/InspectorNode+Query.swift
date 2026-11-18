#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

extension InspectorNode {
    /// String, font, color, line count and truncation of a `Text`.
    public var text: TextInfo? { info.text }

    /// Font of a `Text` or of a UIKit label / text field.
    public var font: FontInfo? { info.text?.font ?? info.uikit?.font }

    /// Declared and measured insets of a `.padding`.
    public var padding: PaddingInfo? { info.padding }

    /// Axis, alignment and declared spacing of a stack or a custom `Layout`.
    public var stack: StackInfo? { info.stack }

    /// Values of a `.frame(…)`.
    public var frameRule: FrameRule? { info.frameRule }

    /// Gaps between consecutive children of a stack as laid out (including the real default spacing).
    public var measuredGaps: [CGFloat] {
        guard let stack, children.count > 1 else { return [] }
        return InspectorRenderer.measuredGaps(self, axis: stack.axis)
    }

    /// The closest app-defined view this node belongs to.
    public var enclosingComponent: InspectorNode? {
        var node = parent
        while let current = node {
            if current.kind == .component { return current }
            node = current.parent
        }
        return nil
    }

    /// Every node below this one, depth first; only `kind` when given.
    public func descendants(_ kind: NodeKind? = nil) -> [InspectorNode] {
        var result: [InspectorNode] = []
        for child in children {
            child.forEach { if kind == nil || $0.kind == kind { result.append($0) } }
        }
        return result
    }

    /// This node or the first node below it whose title or text equals `query`, or whose detail contains it.
    public func find(_ query: String, kind: NodeKind? = nil) -> InspectorNode? {
        first { node in
            (kind == nil || node.kind == kind)
                && (node.title == query || node.info.text?.string == query || (node.detail?.contains(query) ?? false))
        }
    }
}

#endif
