#if LayoutInspectorEngine && os(iOS)
import UIKit

/// Approach #4 – a text "layout snapshot": stable, diff-able description of what is on screen.
/// Good for CI (no pixel noise) and for sharing from the device.
public enum LayoutReport {
    public struct Options {
        public var includeFrames = true
        public var includeRenderTree = false
        public init() {}
    }

    public static func text(for capture: InspectorCapture, options: Options = Options()) -> String {
        var lines: [String] = []
        lines.append("# Layout report – \(capture.isSwiftUIGraphAvailable ? "SwiftUI graph" : "render tree only")")
        for root in capture.swiftUIRoots {
            lines.append("")
            lines.append("## \(root.title)")
            for child in root.children { dump(child, indent: 0, into: &lines, options: options) }
        }
        if options.includeRenderTree {
            lines.append("")
            lines.append("## UIKit")
            dumpUIKit(capture.uikitRoot, indent: 0, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func dump(_ node: InspectorNode, indent: Int, into lines: inout [String], options: Options) {
        var line = String(repeating: "  ", count: indent) + node.title
        if let detail = node.detail { line += " \(detail)" }
        var facts: [String] = []
        if let t = node.info.text {
            if let f = t.font { facts.append(f.displayName) }
            if let c = t.colorHex { facts.append(c) }
            if let l = t.lineCount, l > 1 { facts.append("\(l) lines") }
            if t.isTruncated { facts.append("TRUNCATED") }
        }
        if let p = node.info.padding { facts.append("measured \(p.measured.compact)\(p.isSystem ? " (system)" : "")") }
        if node.kind == .stack, let s = node.info.stack {
            let gaps = InspectorRenderer.measuredGaps(node, axis: s.axis)
            if !gaps.isEmpty { facts.append("gaps " + Set(gaps.map(\.pt)).sorted().joined(separator: "/")) }
        }
        if !node.info.decorations.isEmpty { facts.append(node.info.decorations.joined(separator: " ")) }
        if options.includeFrames, !node.frame.isNull {
            facts.append("@ \(node.frame.minX.pt),\(node.frame.minY.pt) \(node.frame.sizeLabel)")
        }
        if !facts.isEmpty { line += "  [" + facts.joined(separator: " | ") + "]" }
        lines.append(line)
        for child in node.children { dump(child, indent: indent + 1, into: &lines, options: options) }
    }

    private static func dumpUIKit(_ node: InspectorNode, indent: Int, into lines: inout [String]) {
        guard node.kind == .uikitView, let ui = node.info.uikit else { return }
        var line = String(repeating: "  ", count: indent) + ui.className
        if let font = ui.font, ui.text != nil { line += " [\(font.displayName)]" }
        if !node.frame.isNull { line += " @ \(node.frame.minX.pt),\(node.frame.minY.pt) \(node.frame.sizeLabel)" }
        lines.append(line)
        for c in ui.constraints { lines.append(String(repeating: "  ", count: indent + 1) + "⊢ " + c.text) }
        for child in node.children { dumpUIKit(child, indent: indent + 1, into: &lines) }
    }
}

/// Renders a view (normally a window) plus the inspector overlay into an image. Used by snapshot tests and
/// by code run outside of an app, e.g. Xcode's `RunCodeSnippet`.
@MainActor
public enum InspectorImageRenderer {
    public static func image(of view: UIView, capture: InspectorCapture?, options: InspectorRenderOptions?, scale: CGFloat = 2) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(view.bounds)
            // `drawHierarchy` draws nothing for a window without a scene – the only kind there is in a
            // snippet process. The layer tree renders without one.
            if ((view as? UIWindow) ?? view.window)?.windowScene != nil {
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            } else {
                view.layoutIfNeeded()
                view.layer.render(in: context.cgContext)
            }
            if let capture, let options {
                capture.resolveFrames(in: view)
                InspectorRenderer(capture: capture, space: view, bounds: view.bounds, options: options).draw(in: context.cgContext)
            }
        }
    }
}

#endif
