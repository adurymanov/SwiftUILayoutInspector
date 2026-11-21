#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

extension InspectorRenderer {
    /// Components tinted from cold (blue, few body runs) to hot (red), each labelled with its count.
    func drawRerenders(_ ctx: CGContext, _ tags: TagPlacer) {
        guard RenderProfiler.isAvailable else {
            banner(ctx, "Re-render counts are not available on this iOS version.", color: Palette.warning)
            return
        }
        if options.renderCounts?.isGraphFound == false {
            banner(ctx, "Re-render counts are not available: the inspector can't reach SwiftUI's view graph on this iOS version.",
                   color: Palette.warning)
            return
        }
        let components = nodes.filter { $0.kind == .component }
        // Larger views first, so nested ones are drawn on top of their containers.
        let ordered = components.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        let counts = options.renderCounts ?? RenderCounts()
        let scale = log1p(max(counts.maxPerView, 1))

        for node in ordered {
            guard let entry = counts.byNode[node.id] else {
                stroke(ctx, node.frame, Palette.neutral.withAlphaComponent(0.6), width: 0.75, dash: [3, 2])
                continue
            }
            let heat = entry.count == 0 ? 0 : max(0.08, log1p(entry.perView) / scale)
            let color = Self.heatColor(heat)
            fill(ctx, node.frame, color.withAlphaComponent(entry.count == 0 ? 0.04 : 0.12 + 0.3 * heat))
            stroke(ctx, node.frame, color, width: entry.count == 0 ? 0.75 : 1.5)
        }
        guard options.showLabels else { return }
        // Hot views get their labels first: when labels collide, the cold ones give way.
        let labelled = ordered.compactMap { node in counts.byNode[node.id].map { (node, $0) } }
            .sorted { $0.1.perView > $1.1.perView }
        for (node, entry) in labelled {
            let heat = entry.count == 0 ? 0 : max(0.08, log1p(entry.perView) / scale)
            tags.place("\(node.title) \(entry.label)", near: node.frame, color: Self.heatColor(heat).withAlphaComponent(0.95), ctx: ctx)
        }
        var lines = ["body runs since the mode was turned on or reset"]
        if let hottest = counts.hottest, hottest.entry.count > 0, let node = capture.node(withID: hottest.id) {
            lines.insert("hottest: \(node.title) \(hottest.entry.label)", at: 0)
        }
        if counts.byNode.values.contains(where: { $0.instances > 1 }) {
            lines.append("Σn/k: n runs shared by k views of one type")
        }
        card(ctx, title: "Re-renders", lines: lines)
    }

    /// 0 – blue, 0.5 – green, 1 – red.
    static func heatColor(_ heat: Double) -> UIColor {
        let t = min(max(heat, 0), 1)
        return UIColor(hue: 0.62 * (1 - t), saturation: 0.9, brightness: 0.95, alpha: 1)
    }
}

#endif
