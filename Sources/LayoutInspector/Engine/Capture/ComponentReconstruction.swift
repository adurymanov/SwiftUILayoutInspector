#if LayoutInspectorEngine && os(iOS)
import UIKit

/// Restores app-defined views (`ProfileHeader`, `StatsRow`, `TagCloud`…) in the `_ViewDebug` tree.
///
/// Why: on iOS 18+ `_ViewDebug` only serialises *view* tree elements. App views inside stacks are built as
/// *view lists* (flag 1 in AttributeGraph) and are dropped – their content is hoisted into the parent.
/// AttributeGraph still has those list elements, together with the chain of types the view's `body`
/// resolves to (`ProfileHeader` → `HStack<TupleView<(…)>>`). We read that chain, find the same chain of
/// types in the `_ViewDebug` tree and insert a synthetic component node above it.
///
/// Custom `Layout`s are hoisted the same way (their subviews end up in the parent), so for
/// `body = FlowLayout { ForEach … }` we match the ForEach *items* and group them back.
struct ComponentReconstruction {
    struct Component {
        let typeName: String
        let name: String
        let chain: [String]              // body type chain, outermost first (includes nested app views' chains)
        var hoistedLayout: (name: String, typeName: String, itemChains: [[String]])?
    }

    private(set) var components: [Component] = []
    /// Human-readable matching log (exposed via `LayoutCapture.lastReconstructionLog`).
    static var log: [String] = []

    init(trees: [AttributeGraphTree.Element]) {
        var firstByType: [String: AttributeGraphTree.Element] = [:]
        for tree in trees { index(tree, into: &firstByType) }

        var seen = Set<String>()
        for tree in trees {
            visit(tree) { element in
                guard element.flags == 1, Self.isReconstructable(element.typeName), !seen.contains(element.typeName),
                      !element.children.isEmpty else { return }
                seen.insert(element.typeName)
                let chain = Self.chain(from: element)
                var component = Component(typeName: element.typeName, name: TypeNames.shortName(of: element.typeName), chain: chain)
                if let last = chain.last, let layout = Self.hoistedLayout(last, firstByType: firstByType) {
                    component.hoistedLayout = layout
                }
                components.append(component)
            }
        }
    }

    /// SwiftUI views that are built as view lists too (and therefore missing from `_ViewDebug`).
    /// (Toggle/TextField/Picker rows share most internals with `LabeledContent` – too ambiguous to match by type;
    /// they are recognised from their `Switch` / `SystemTextField` leaves instead.)
    static let systemViews = ["Button", "NavigationLink", "Menu", "Link", "ShareLink", "ScrollView", "List", "ProgressView"]

    static func isReconstructable(_ typeName: String) -> Bool {
        if TypeNames.isAppType(typeName) { return true }
        guard typeName.hasPrefix("SwiftUI.") else { return false }
        let base = TypeNames.base(of: String(typeName.dropFirst("SwiftUI.".count)))
        // `Button<PrimitiveButtonStyleConfiguration.Label>` etc. are SwiftUI re-wrapping its own content.
        return systemViews.contains(base) && !typeName.contains("Configuration")
    }

    private func index(_ e: AttributeGraphTree.Element, into map: inout [String: AttributeGraphTree.Element]) {
        if map[e.typeName] == nil || (map[e.typeName]!.children.isEmpty && !e.children.isEmpty) { map[e.typeName] = e }
        e.children.forEach { index($0, into: &map) }
    }

    private func visit(_ e: AttributeGraphTree.Element, _ body: (AttributeGraphTree.Element) -> Void) {
        body(e)
        e.children.forEach { visit($0, body) }
    }

    /// Types along the first-child path below `element` (continuing through nested app views).
    static func chain(from element: AttributeGraphTree.Element) -> [String] {
        var result: [String] = []
        var current = element
        var steps = 0
        while let next = current.children.first, steps < 200 {
            if next.typeName != "?" { result.append(next.typeName) }
            current = next
            steps += 1
            if next.flags == 0 && next.typeName != "?" && !TypeNames.isAppType(next.typeName) { break }
        }
        return result
    }

    /// `_VariadicView.Tree<_LayoutRoot<FlowLayout>, ForEach<…>>` – a custom Layout, never present in `_ViewDebug`.
    private static func hoistedLayout(_ type: String, firstByType: [String: AttributeGraphTree.Element]) -> (String, String, [[String]])? {
        guard type.hasPrefix("SwiftUI._VariadicView.Tree<") else { return nil }
        let fullArgs = TypeNames.genericArguments(of: type)
        guard fullArgs.count == 2, fullArgs[0].contains("_LayoutRoot<") else { return nil }
        let layoutType = String(fullArgs[0].drop { $0 != "<" }.dropFirst().dropLast())
        var contentTypes = [fullArgs[1]]
        if fullArgs[1].hasPrefix("SwiftUI.TupleView<") {
            let tuple = TypeNames.genericArguments(of: fullArgs[1]).first ?? ""
            contentTypes = TypeNames.genericArguments(of: "X<" + tuple.dropFirst().dropLast() + ">")
        }
        let itemChains = contentTypes.compactMap { firstByType[$0].map(chain(from:)) }.filter { !$0.isEmpty }
        return (TypeNames.shortName(of: layoutType), layoutType, itemChains)
    }

    // MARK: - Applying to the `_ViewDebug` tree

    /// Wrapper types that show up everywhere – useless as anchors.
    private static let genericBases: Set<String> = [
        "EmptyModifier", "HiddenForReuseEffect", "AccessibilityAttachmentModifier", "_ViewList_View",
        "PlaceholderContentView", "OpacityRendererEffect", "_ViewModifier_Content",
    ]

    /// Inserts synthetic component nodes into `roots` (mutates the raw tree in place).
    func apply(to roots: [RawDebugNode]) {
        var byType: [String: [RawDebugNode]] = [:]
        for root in roots { root.forEach { byType[$0.typeName, default: []].append($0) } }

        // Outer components first: when two components resolve to the same node, the outer one ends up on top.
        let ordered = components.sorted { $0.chain.count > $1.chain.count }
        var claimed = Set<String>()

        for component in ordered {
            if let layout = component.hoistedLayout {
                applyHoisted(component, layout: layout, byType: byType)
                continue
            }
            guard let match = anchor(in: component.chain, byType: byType) else {
                Self.log.append("\(component.name): no anchor")
                continue
            }
            let isSystem = !TypeNames.isAppType(component.typeName)
            var count = 0
            for node in byType[component.chain[match]] ?? [] {
                let root = climb(from: node, chain: component.chain, anchorIndex: match)
                // System views erase their content type (Button<A> and Button<B> share internals) – one per root.
                let key = "\(isSystem ? component.name : component.typeName)#\(ObjectIdentifier(root).hashValue)"
                if claimed.contains(key) { continue }
                claimed.insert(key)
                let readable = isSystem ? AttributeGraphTree.readable(component.typeName) : component.name
                wrap([root], typeName: component.typeName, readable: readable)
                count += 1
            }
            Self.log.append("\(component.name): anchor \(AttributeGraphTree.readable(component.chain[match]).prefix(70)) → \(count)")
        }
    }

    /// The most specific chain type present in the JSON: fewest occurrences, then the most detailed type name.
    private func anchor(in chain: [String], byType: [String: [RawDebugNode]]) -> Int? {
        let candidates = chain.indices.filter { i in
            guard let nodes = byType[chain[i]], !nodes.isEmpty else { return false }
            let type = chain[i]
            if Self.genericBases.contains(TypeNames.shortName(of: type)) { return false }
            // Plain `Text`, `_PaddingLayout`, `Spacer`… say nothing about *which* view this is.
            return type.contains("<") || TypeNames.isAppType(type)
        }
        guard let best = candidates.min(by: { a, b in
            let ca = byType[chain[a]]!.count, cb = byType[chain[b]]!.count
            if ca != cb { return ca < cb }
            if chain[a].count != chain[b].count { return chain[a].count > chain[b].count }
            return a < b
        }) else { return nil }
        return best
    }

    /// Walks up from the anchor while ancestors are earlier links of the same chain (monotonically).
    private func climb(from node: RawDebugNode, chain: [String], anchorIndex: Int) -> RawDebugNode {
        var root = node
        var index = anchorIndex
        var misses = 0
        var current = node.parent
        while let a = current, misses < 8, index > 0 {
            if !a.isSynthetic, let i = chain[..<index].lastIndex(of: a.typeName) {
                root = a
                index = i
                misses = 0
            } else {
                misses += 1
            }
            current = a.parent
        }
        return root
    }

    private func applyHoisted(_ component: Component, layout: (name: String, typeName: String, itemChains: [[String]]),
                              byType: [String: [RawDebugNode]]) {
        var items: [RawDebugNode] = []
        for itemChain in layout.itemChains {
            guard let match = anchor(in: itemChain, byType: byType) else { continue }
            for node in byType[itemChain[match]] ?? [] {
                let root = climb(from: node, chain: itemChain, anchorIndex: match)
                if !items.contains(where: { $0 === root }) { items.append(root) }
            }
        }
        Self.log.append("\(component.name): layout \(layout.name) chains \(layout.itemChains.map(\.count)) items \(items.count)")
        // Group by parent: every group is one instance of the custom layout.
        var groups: [ObjectIdentifier: [RawDebugNode]] = [:]
        var order: [ObjectIdentifier] = []
        for var item in items {
            // Lift the item to its slot in the container (top of its single-child chain).
            while let p = item.parent, p.children.count == 1, p.parent != nil { item = p }
            guard let parent = item.parent else { continue }
            let id = ObjectIdentifier(parent)
            if groups[id] == nil { order.append(id) }
            if !(groups[id]?.contains { $0 === item } ?? false) { groups[id, default: []].append(item) }
        }
        for id in order {
            guard let group = groups[id] else { continue }
            let layoutNode = wrap(group, typeName: "SwiftUI._VariadicView.Tree<SwiftUI._LayoutRoot<\(layout.typeName)>, Content>",
                                  readable: "_VariadicView.Tree<_LayoutRoot<\(layout.name)>, Content>")
            wrap([layoutNode], typeName: component.typeName, readable: component.name)
        }
    }

    /// Replaces `nodes` (siblings) with a synthetic node containing them.
    @discardableResult
    private func wrap(_ nodes: [RawDebugNode], typeName: String, readable: String) -> RawDebugNode {
        let parent = nodes.first?.parent
        let boxes = nodes.compactMap(\.firstGeometry)
        let union = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }
        // A single wrapped node keeps inheriting geometry exactly like the original did.
        let geometry = nodes.count == 1 ? nodes[0].geometry : union
        let synthetic = RawDebugNode(syntheticType: typeName, readable: readable, children: nodes, geometry: geometry)
        if let parent, let index = parent.children.firstIndex(where: { $0 === nodes[0] }) {
            parent.children.removeAll { child in nodes.contains { $0 === child } }
            parent.children.insert(synthetic, at: min(index, parent.children.count))
            synthetic.parent = parent
        }
        return synthetic
    }
}

#endif
