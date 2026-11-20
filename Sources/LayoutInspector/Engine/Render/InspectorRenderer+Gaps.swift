#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

extension InspectorRenderer {
    static func measuredGaps(_ node: InspectorNode, axis: StackInfo.Axis) -> [CGFloat] {
        guard axis == .vertical || axis == .horizontal else { return [] }
        let vertical = axis == .vertical
        let frames = node.children.map(\.frame).filter { !$0.isNull }.sorted { vertical ? $0.minY < $1.minY : $0.minX < $1.minX }
        guard var end = frames.first.map({ vertical ? $0.maxY : $0.maxX }) else { return [] }
        var gaps: [CGFloat] = []
        for f in frames.dropFirst() {
            let start = vertical ? f.minY : f.minX
            if start - end > 0.25 { gaps.append(start - end) }
            end = max(end, vertical ? f.maxY : f.maxX)
        }
        return gaps
    }
}

#endif
