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
        let own = counts.byNode.filter { $0.value.instances == 1 }
        let scale = log1p(max(own.values.map(\.perView).max() ?? 0, 1))
        let showsZeros = options.showsZeroRenders
        let containers = Self.markedContainers(components, counts: counts, showsZeros: showsZeros)

        for node in ordered {
            guard let entry = counts.byNode[node.id] else {
                if showsZeros { stroke(ctx, node.frame, Palette.neutral.withAlphaComponent(0.6), width: 0.75, dash: [3, 2]) }
                continue
            }
            // A count shared by views that can't be told apart says nothing about this one: a faint outline, and the
            // total once, in the panel.
            if entry.instances > 1 {
                if showsZeros || entry.count > 0 { stroke(ctx, node.frame, Palette.neutral.withAlphaComponent(0.45), width: 0.75, dash: [2, 2]) }
                continue
            }
            guard entry.count > 0 || showsZeros else { continue }
            let heat = entry.count == 0 ? 0 : max(0.08, log1p(entry.perView) / scale)
            let color = Self.heatColor(heat)
            // Fills of nested views stack up into an opaque layer on a deep screen: only the innermost marked views
            // are filled, faintly; the outline and the label carry the heat.
            if !containers.contains(node.id) {
                fill(ctx, node.frame, color.withAlphaComponent(Self.fillAlpha(heat: heat, rendered: entry.count > 0)))
            }
            stroke(ctx, node.frame, color, width: entry.count == 0 ? 0.75 : 1 + heat)
        }
        if options.showLabels {
            // Hot views get their labels first: when labels collide, the cold ones give way.
            let labelled = ordered.compactMap { node in own[node.id].map { (node, $0) } }
                .filter { showsZeros || $0.1.count > 0 }
                .sorted { $0.1.perView > $1.1.perView }
            for (node, entry) in labelled {
                let heat = entry.count == 0 ? 0 : max(0.08, log1p(entry.perView) / scale)
                tags.place("\(node.title) \(entry.label)", near: node.frame, color: Self.heatColor(heat).withAlphaComponent(0.95), ctx: ctx)
            }
        }
        card(ctx, title: "Re-renders", lines: Self.panelLines(counts, capture: capture, showsZeros: showsZeros))
    }

    /// The hottest view, and each type whose views share one count, once.
    static func panelLines(_ counts: RenderCounts, capture: InspectorCapture, showsZeros: Bool) -> [String] {
        var lines: [String] = []
        if let hottest = counts.byNode.filter({ $0.value.instances == 1 }).max(by: { $0.value.count < $1.value.count }),
           hottest.value.count > 0, let node = capture.node(withID: hottest.key) {
            lines.append("hottest: \(node.title) \(hottest.value.label)")
        } else {
            lines.append("no view re-rendered since the mode was turned on or reset")
        }
        let summary = counts.summary
        if summary.shared > 0 {
            lines.append("\(summary.shared) of \(summary.views) views share a count with views they can't be told from:")
            lines += counts.sharedGroups(in: capture).map(\.line)
        }
        if !showsZeros { lines.append("views that didn't re-render are not marked (Dev → Show zeros)") }
        return lines
    }

    /// The fill of an innermost marked view: at most 0.12, so the screen stays readable where a few overlap.
    static func fillAlpha(heat: Double, rendered: Bool) -> CGFloat {
        rendered ? 0.04 + 0.08 * min(max(heat, 0), 1) : 0.02
    }

    /// Views drawn with a fill of their own that hold another such view: outlined only.
    static func markedContainers(_ components: [InspectorNode], counts: RenderCounts, showsZeros: Bool) -> Set<Int> {
        var containers = Set<Int>()
        for node in components {
            guard let entry = counts.byNode[node.id], entry.instances == 1, entry.count > 0 || showsZeros else { continue }
            var parent = node.parent
            while let ancestor = parent, containers.insert(ancestor.id).inserted { parent = ancestor.parent }
        }
        return containers
    }

    /// 0 – blue, 0.5 – green, 1 – red.
    static func heatColor(_ heat: Double) -> UIColor {
        let t = min(max(heat, 0), 1)
        return UIColor(hue: 0.62 * (1 - t), saturation: 0.9, brightness: 0.95, alpha: 1)
    }
}

#endif
