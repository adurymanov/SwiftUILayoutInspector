#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// `capture.json`: a capture as data, for agents and scripts. The schema is documented in `Docs/Agents.md`; bump
/// `schemaVersion` on any change a reader could trip over (a removed or renamed key, a changed unit or meaning).
/// New keys don't need a bump.
enum CaptureJSON {
    static let schemaVersion = 1

    /// Component properties hold app data, so they go to disk only when asked for: `LAYOUT_INSPECTOR_PROPERTIES=1`.
    static var includesProperties = ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_PROPERTIES"] == "1"

    /// `space` – the view the node frames were last resolved in (window points for the inspector on screen).
    /// `renderCounts` – body runs while Re-renders is on (`renders` of a component).
    static func object(for capture: InspectorCapture, rules: LayoutInspector.LintRules, bounds: CGRect, space: UIView?,
                       renderCounts: RenderCounts? = nil) -> [String: Any] {
        var nodes: [[String: Any]] = []
        let graphViews = includesProperties && capture.swiftUINodes.contains { $0.kind == .component } ? ComponentGraph.match(capture) : [:]
        func visit(_ node: InspectorNode, tree: String, component: String?) {
            var o = describe(node, tree: tree, component: component)
            if let entry = renderCounts?.byNode[node.id] { o["renders"] = ["count": entry.count, "views": entry.instances] }
            if let match = graphViews[node.id], match.isExact, let view = match.views.first, let value = ComponentGraph.value(of: view) {
                o["properties"] = ComponentDetails.properties(of: value).map { property -> [String: Any] in
                    var p: [String: Any] = ["name": property.name, "kind": property.kind.rawValue, "type": property.type]
                    if let value = property.value { p["value"] = value }
                    return p
                }
            }
            nodes.append(o)
            let inner = node.kind == .component ? node.title : component
            for child in node.children { visit(child, tree: tree, component: inner) }
        }
        for root in capture.swiftUIRoots { visit(root, tree: "swiftui", component: nil) }
        visitUIKit(capture.uikitRoot, into: &nodes)

        let lint: [[String: Any]] = capture.lintIssues(rules: rules, in: bounds).filter { !$0.message.isEmpty }.map { issue in
            ["id": issue.id, "severity": issue.severity.rawValue, "message": issue.message, "node": issue.nodeID, "rect": rect(issue.rect)]
        }
        var object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "library": LayoutInspector.version,
            "graph": capture.isSwiftUIGraphAvailable,
            "nodes": nodes,
            "lint": lint,
        ]
        if let renderCounts {
            let summary = renderCounts.summary
            object["renders"] = ["views": summary.views, "own": summary.own, "shared": summary.shared,
                                 "groups": renderCounts.sharedGroups(in: capture).map { group -> [String: Any] in
                                     ["title": group.title, "count": group.count, "components": group.components, "graphViews": group.graphViews]
                                 }] as [String: Any]
        }
        if let host = capture.swiftUIRoots.first {
            object["environment"] = Dictionary(ComponentDetails.environment(of: host).map { ($0.name, $0.value) }) { a, _ in a }
        }
        if let space {
            object["space"] = ["width": round(space.bounds.width), "height": round(space.bounds.height),
                               "scale": space.window?.screen.scale ?? UIScreen.main.scale] as [String: Any]
        }
        return object
    }

    private static func describe(_ node: InspectorNode, tree: String, component: String?) -> [String: Any] {
        var o: [String: Any] = [
            "id": node.id,
            "tree": tree,
            "kind": node.kind.rawValue,
            "title": node.title,
            "type": node.typeName.count > 300 ? String(node.typeName.prefix(300)) + "…" : node.typeName,
            "visible": node.isVisible,
        ]
        if let parent = node.parent { o["parent"] = parent.id }
        if let detail = node.detail, !detail.isEmpty { o["detail"] = detail }
        if let component { o["component"] = component }
        o["frame"] = node.frame.isNull ? NSNull() : rect(node.frame)
        let info = node.info
        if let text = info.text {
            var t: [String: Any] = ["string": text.string, "truncated": text.isTruncated]
            if let font = text.font { t["font"] = self.font(font) }
            if let color = text.colorHex { t["color"] = color }
            if let alignment = text.alignment { t["alignment"] = alignment }
            if let lines = text.lineCount { t["lines"] = lines }
            if let baseline = text.firstBaseline { t["firstBaseline"] = round(baseline) }
            if let kerning = text.kerning { t["kerning"] = round(kerning) }
            o["text"] = t
        }
        if let padding = info.padding {
            var p: [String: Any] = ["measured": edges(padding.measured), "system": padding.isSystem, "edges": padding.edges]
            p["declared"] = padding.declared.map(edges) ?? NSNull()
            o["padding"] = p
        }
        if let stack = info.stack {
            var s: [String: Any] = ["axis": stack.axis.rawValue, "name": stack.name]
            if let alignment = stack.alignment { s["alignment"] = alignment }
            s["spacing"] = stack.spacing.map(round) ?? NSNull()
            if node.children.count > 1 { s["gaps"] = InspectorRenderer.measuredGaps(node, axis: stack.axis).map(round) }
            o["stack"] = s
        }
        if let gaps = siblingGaps(node) { o["siblingGaps"] = gaps }
        var constraints: [String: Any] = [:]
        if let rule = info.frameRule { constraints["frame"] = rule.code }
        if let fixed = info.fixedSize { constraints["fixedSize"] = ["horizontal": fixed.horizontal, "vertical": fixed.vertical] }
        if let priority = info.layoutPriority { constraints["layoutPriority"] = priority }
        if let length = info.spacerMinLength { constraints["spacerMinLength"] = round(length) }
        if let ratio = info.aspectRatio {
            constraints["aspectRatio"] = ["ratio": ratio.ratio.map(round) ?? NSNull(), "contentMode": ratio.contentMode] as [String: Any]
        }
        if let offset = info.offset { constraints["offset"] = ["width": round(offset.width), "height": round(offset.height)] }
        if !constraints.isEmpty { o["constraints"] = constraints }
        if let image = info.image {
            var i: [String: Any] = ["name": image.name, "symbol": image.isSymbol]
            if let size = image.naturalSize { i["naturalSize"] = ["width": round(size.width), "height": round(size.height)] }
            o["image"] = i
        }
        if let shape = info.shapeName { o["shape"] = shape }
        if let fill = info.fill { o["fill"] = fill }
        if !info.decorations.isEmpty { o["decorations"] = info.decorations }
        return o
    }

    /// UIKit views (render layers left out) with what UIKit knows about them.
    private static func visitUIKit(_ node: InspectorNode, into nodes: inout [[String: Any]]) {
        guard node.kind == .uikitView else { return }
        var o = describe(node, tree: "uikit", component: nil)
        if let ui = node.info.uikit {
            var u: [String: Any] = ["className": ui.className, "autoLayout": ui.usesAutoLayout, "appView": ui.isAppView]
            if let text = ui.text { u["text"] = text }
            if let font = ui.font { u["font"] = self.font(font) }
            if let color = ui.textColorHex { u["color"] = color }
            if !ui.constraints.isEmpty { u["constraints"] = ui.constraints.map(\.text) }
            if ui.hasAmbiguousLayout { u["ambiguous"] = true }
            if let spacing = ui.stackSpacing { u["stackSpacing"] = round(spacing) }
            o["uikit"] = u
            if let view = node.anchor.view, let facts = AccessibilityFacts.of(view) { o["accessibility"] = facts }
        }
        nodes.append(o)
        for child in node.children { visitUIKit(child, into: &nodes) }
    }

    /// Gaps to the previous and next child of the parent stack, along its axis (what Spacing draws between them).
    private static func siblingGaps(_ node: InspectorNode) -> [String: Any]? {
        guard let parent = node.parent, parent.kind == .stack, let axis = parent.info.stack?.axis,
              axis == .vertical || axis == .horizontal, !node.frame.isNull else { return nil }
        let vertical = axis == .vertical
        let siblings = parent.children.filter { !$0.frame.isNull }
            .sorted { vertical ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        guard siblings.count > 1, let index = siblings.firstIndex(where: { $0 === node }) else { return nil }
        var gaps: [String: Any] = ["axis": axis.rawValue]
        if index > 0 {
            let previous = siblings[index - 1].frame
            gaps["before"] = round(vertical ? node.frame.minY - previous.maxY : node.frame.minX - previous.maxX)
        }
        if index < siblings.count - 1 {
            let next = siblings[index + 1].frame
            gaps["after"] = round(vertical ? next.minY - node.frame.maxY : next.minX - node.frame.maxX)
        }
        return gaps
    }

    private static func font(_ f: FontInfo) -> [String: Any] {
        var o: [String: Any] = ["family": f.family, "postScriptName": f.postScriptName, "size": round(f.size),
                                "weight": f.weight, "lineHeight": round(f.lineHeight), "display": f.displayName]
        o["textStyle"] = f.textStyle ?? NSNull()
        return o
    }

    private static func edges(_ e: EdgeValues) -> [String: Any] {
        ["top": round(e.top), "leading": round(e.leading), "bottom": round(e.bottom), "trailing": round(e.trailing)]
    }

    /// `[x, y, width, height]` in points, two decimals.
    static func rect(_ r: CGRect) -> Any {
        r.isNull || r.isInfinite ? NSNull() : [round(r.minX), round(r.minY), round(r.width), round(r.height)]
    }

    /// Two decimals, like the overlay's labels; infinities become `nil`.
    static func round(_ v: CGFloat) -> Any {
        guard v.isFinite else { return NSNull() }
        return Double((v * 100).rounded() / 100)
    }
}

#endif
