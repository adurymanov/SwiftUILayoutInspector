#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI

/// Everything known about one node: geometry, layout modifiers, typography, stack, UIKit and raw debug values.
/// The inspector shows it when an element is tapped.
public struct NodeDetailsView: View {
    let node: InspectorNode
    var onClose: (() -> Void)?

    public init(node: InspectorNode, onClose: (() -> Void)? = nil) {
        self.node = node
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon(for: node.kind)).foregroundStyle(Color(Palette.color(for: node.kind)))
                Text(node.title).font(.headline)
                if let detail = node.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if let onClose { Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }
            Text(breadcrumb).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sections, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Color(.secondaryLabel))
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.0).font(.caption).foregroundStyle(Color(.secondaryLabel)).frame(width: 96, alignment: .leading)
                                    Text(row.1).font(.caption.monospaced()).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private var breadcrumb: String {
        node.path.filter { [.component, .stack, .scroll, .list, .control, .host].contains($0.kind) || $0 === node }
            .map(\.title).joined(separator: " › ")
    }

    private var sections: [(String, [(String, String)])] {
        var result: [(String, [(String, String)])] = []
        let f = node.frame
        var geometry: [(String, String)] = [("frame", "x \(f.minX.pt)  y \(f.minY.pt)  \(f.width.pt)×\(f.height.pt)")]
        if let parent = node.parent, parent.kind != .host, parent.isVisible {
            let p = parent.frame
            geometry.append(("in parent", "x \((f.minX - p.minX).pt)  y \((f.minY - p.minY).pt)"))
        }
        result.append(("Geometry", geometry))

        // Layout modifiers wrapping this view (outermost first).
        var chain: [String] = []
        var p = node.parent
        while let n = p, n.kind.isLayoutModifier { chain.insert(n.label, at: 0); p = n.parent }
        if !chain.isEmpty || !node.info.decorations.isEmpty {
            result.append(("Modifiers", chain.map { ("layout", $0) } + node.info.decorations.map { ("style", $0) }))
        }

        if let t = node.info.text {
            var rows: [(String, String)] = [("string", "“\(t.string)”")]
            if let font = t.font {
                rows.append(("font", font.displayName))
                rows.append(("family", font.postScriptName))
                rows.append(("dynamic type", font.isDynamicType ? "yes (\(font.textStyle!))" : "no – fixed size"))
                rows.append(("line height", font.lineHeight.pt))
            }
            if let lines = t.lineCount { rows.append(("lines", "\(lines)")) }
            if let c = t.colorHex { rows.append(("color", c)) }
            if let a = t.alignment { rows.append(("alignment", a)) }
            if let k = t.kerning { rows.append(("kerning", k.pt)) }
            if let b = t.firstBaseline { rows.append(("first baseline", b.pt)) }
            rows.append(("truncated", t.isTruncated ? "YES" : "no"))
            if t.runCount > 1 { rows.append(("runs", "\(t.runCount) attributed runs")) }
            result.append(("Typography", rows))
        }
        if let pad = node.info.padding {
            var rows: [(String, String)] = [("declared", pad.declared?.compact ?? "default (.padding())"), ("measured", pad.measured.compact)]
            if pad.isSystem { rows.append(("source", "system (List / control)")) }
            result.append(("Padding", rows))
        }
        if let rule = node.info.frameRule {
            result.append(("Frame constraint", [("code", rule.code), ("result", f.sizeLabel)]))
        }
        if let s = node.info.stack {
            var rows: [(String, String)] = [("type", s.name), ("spacing", s.spacing.map(\.pt) ?? "default (adaptive)")]
            if let a = s.alignment { rows.append(("alignment", a)) }
            let measured = node.children.count > 1 ? InspectorRenderer.measuredGaps(node, axis: s.axis) : []
            if !measured.isEmpty { rows.append(("measured gaps", measured.map(\.pt).joined(separator: ", "))) }
            result.append(("Stack", rows))
        }
        if let img = node.info.image {
            var rows: [(String, String)] = [("name", img.name), ("kind", img.isSymbol ? "SF Symbol" : "asset")]
            if let s = img.naturalSize { rows.append(("natural size", "\(s.width.pt)×\(s.height.pt)")) }
            result.append(("Image", rows))
        }
        if let shape = node.info.shapeName { result.append(("Shape", [("shape", shape), ("fill", node.info.fill ?? "—")])) }
        if let m = node.info.spacerMinLength { result.append(("Spacer", [("minLength", m.pt)])) }
        if let fs = node.info.fixedSize { result.append(("Fixed size", [("horizontal", "\(fs.horizontal)"), ("vertical", "\(fs.vertical)")])) }
        if let lp = node.info.layoutPriority { result.append(("Priority", [("layoutPriority", CGFloat(lp).pt)])) }

        if let ui = node.info.uikit {
            var rows: [(String, String)] = [("class", ui.className)]
            if let font = ui.font { rows.append(("font", font.displayName)) }
            if let t = ui.text { rows.append(("text", t)) }
            if let s = ui.intrinsicSize { rows.append(("intrinsic", "\(s.width.pt)×\(s.height.pt)")) }
            if let h = ui.hugging { rows.append(("hugging", "h \(Int(h.h)) · v \(Int(h.v))")) }
            if let c = ui.compression { rows.append(("compression", "h \(Int(c.h)) · v \(Int(c.v))")) }
            if let i = ui.contentInset { rows.append(("content inset", "t \(i.top.pt) l \(i.left.pt) b \(i.bottom.pt) r \(i.right.pt)")) }
            if let m = ui.layoutMargins { rows.append(("margins", "t \(m.top.pt) l \(m.left.pt) b \(m.bottom.pt) r \(m.right.pt)")) }
            rows.append(("auto layout", ui.usesAutoLayout ? "yes\(ui.hasAmbiguousLayout ? " – AMBIGUOUS" : "")" : "no (autoresizing)"))
            result.append(("UIKit", rows))
            if !ui.constraints.isEmpty {
                result.append(("Constraints", ui.constraints.map { ($0.priority < 1000 ? "optional" : "required", $0.text) }))
            }
        }
        result.append(("Type", [("swift", node.typeName.count > 160 ? String(node.typeName.prefix(160)) + "…" : node.typeName)]))
        if !node.info.raw.isEmpty {
            result.append(("Raw debug values", Array(node.info.raw.prefix(14))))
        }
        return result
    }
}

func icon(for kind: NodeKind) -> String {
    switch kind {
    case .host: "macwindow"
    case .component: "puzzlepiece.extension"
    case .customModifier: "wand.and.stars"
    case .stack: "square.split.1x2"
    case .scroll: "scroll"
    case .list: "list.bullet.rectangle"
    case .control: "hand.tap"
    case .text: "textformat"
    case .image: "photo"
    case .shape, .color: "square.fill"
    case .spacer: "arrow.left.and.right"
    case .divider: "minus"
    case .platform, .uikitView: "uiwindow.split.2x1"
    case .padding: "square.dashed"
    case .frame, .flexFrame: "ruler"
    case .fixedSize: "pin"
    case .aspectRatio: "aspectratio"
    case .offset: "move.3d"
    case .layoutPriority: "arrow.up.square"
    case .ignoresSafeArea: "rectangle.portrait.arrowtriangle.2.outward"
    case .renderLayer: "square.3.layers.3d"
    }
}

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

/// Outline of the captured tree.
struct NodeTreeView: View {
    let capture: InspectorCapture
    let onSelect: (InspectorNode) -> Void
    @State private var query = ""

    init(capture: InspectorCapture, onSelect: @escaping (InspectorNode) -> Void) {
        self.capture = capture
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(capture.swiftUIRoots) { root in
                    Section(root.title) {
                        OutlineGroup(filtered(root.children), children: \.optionalChildren) { node in
                            Button { onSelect(node) } label: { row(node) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query)
            .navigationTitle("View tree")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func filtered(_ nodes: [InspectorNode]) -> [InspectorNode] {
        guard !query.isEmpty else { return nodes }
        var result: [InspectorNode] = []
        for root in nodes { root.forEach { if $0.label.localizedCaseInsensitiveContains(query) { result.append($0) } } }
        return result
    }

    private func row(_ node: InspectorNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: node.kind)).foregroundStyle(Color(Palette.color(for: node.kind))).frame(width: 18)
            Text(node.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
            if let d = node.detail { Text(d).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text(node.frame.isNull ? "" : node.frame.sizeLabel).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
    }
}

extension InspectorNode {
    var optionalChildren: [InspectorNode]? { children.isEmpty ? nil : children }
}

#endif
