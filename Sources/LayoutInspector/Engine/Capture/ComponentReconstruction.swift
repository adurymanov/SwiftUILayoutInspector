#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
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
        /// Indices of `chain` specific enough to anchor on (see `anchor(in:byType:)`), worked out once.
        var anchorable: [Int] = []
        /// How many of it AttributeGraph holds, in every host.
        var instances = 1
    }

    private(set) var components: [Component] = []
    /// Human-readable matching log (exposed via `LayoutCapture.lastReconstructionLog`).
    static var log: [String] = []

    init(trees: [AttributeGraphTree.Element]) {
        var firstByType: [String: AttributeGraphTree.Element] = [:]
        for tree in trees { index(tree, into: &firstByType) }

        var seen = Set<String>()
        var instances: [String: Int] = [:]
        for tree in trees {
            visit(tree) { element in
                instances[element.typeName, default: 0] += 1
                guard element.flags == 1, Self.isReconstructable(element.typeName) else { return }
                guard !seen.contains(element.typeName), !element.children.isEmpty else { return }
                seen.insert(element.typeName)
                let chain = Self.chain(from: element)
                var component = Component(typeName: element.typeName, name: TypeNames.shortName(of: element.typeName), chain: chain)
                component.anchorable = Self.anchorableIndices(chain)
                if let last = chain.last, let layout = Self.hoistedLayout(last, firstByType: firstByType) {
                    component.hoistedLayout = layout
                }
                components.append(component)
            }
        }
        for i in components.indices { components[i].instances = instances[components[i].typeName] ?? 1 }
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
        // App views wrapped around each node so far, and nodes two unrelated views both claimed.
        var wrappers: [ObjectIdentifier: [(component: Component, node: RawDebugNode)]] = [:]
        var contested: [ObjectIdentifier: [Component]] = [:]

        for component in ordered {
            if let layout = component.hoistedLayout {
                applyHoisted(component, layout: layout, byType: byType)
                continue
            }
            let isSystem = !TypeNames.isAppType(component.typeName)
            guard let placement = placements(of: component, isSystem: isSystem, byType: byType) else { continue }
            let match = placement.anchor
            var count = 0
            for root in placement.roots {
                // System views erase their content type (Button<A> and Button<B> share internals) – one per root.
                let key = "\(isSystem ? component.name : component.typeName)#\(ObjectIdentifier(root).hashValue)"
                if claimed.contains(key) { continue }
                claimed.insert(key)
                // Two app views claim the same node and neither is part of the other's body: sibling views built the
                // same way (`MainTabItem` and `ChatTabItem`, both `HolaTabItem(…)`) in hosts that hold one of them
                // each. Which one this is cannot be told, so the node gets neither.
                let id = ObjectIdentifier(root)
                if !isSystem {
                    if contested[id]?.contains(where: { !Self.isNested(component, $0) }) == true { continue }
                    let rivals = wrappers[id, default: []].filter { !Self.isNested(component, $0.component) }
                    if !rivals.isEmpty {
                        rivals.forEach { unwrap($0.node) }
                        wrappers[id]?.removeAll { wrapper in rivals.contains { $0.node === wrapper.node } }
                        contested[id, default: []] += rivals.map(\.component) + [component]
                        Self.log.append("\(component.name): same node as \(rivals.map(\.component.name).joined(separator: ", ")), left unnamed")
                        continue
                    }
                }
                let readable = isSystem ? AttributeGraphTree.readable(component.typeName) : component.name
                let synthetic = wrap([root], typeName: component.typeName, readable: readable)
                if !isSystem { wrappers[id, default: []].append((component, synthetic)) }
                count += 1
            }
            Self.log.append("\(component.name): anchor \(AttributeGraphTree.readable(component.chain[match]).prefix(70)) → \(count)")
        }
    }

    /// The nodes `component` wraps: the roots its most specific anchor climbs to, without the ones that are a node
    /// of its type already (an app's `GeometryEffect` or `ViewModifier` is in `_ViewDebug` itself). An anchor that
    /// leads to more nodes than the view has instances is not this view's, the name would land on unrelated nodes:
    /// the next anchor is tried, and with none left the view stays unnamed.
    private func placements(of component: Component, isSystem: Bool,
                            byType: [String: [RawDebugNode]]) -> (anchor: Int, roots: [RawDebugNode])? {
        let candidates = component.anchorable.filter { byType[component.chain[$0]]?.isEmpty == false }.sorted { a, b in
            let ca = byType[component.chain[a]]!.count, cb = byType[component.chain[b]]!.count
            if ca != cb { return ca < cb }
            if component.chain[a].count != component.chain[b].count { return component.chain[a].count > component.chain[b].count }
            return a < b
        }
        guard !candidates.isEmpty else {
            Self.log.append("\(component.name): no anchor")
            return nil
        }
        let limit = max(2 * component.instances, component.instances + 2)
        for index in candidates {
            var roots: [RawDebugNode] = []
            for node in byType[component.chain[index]] ?? [] {
                let root = climb(from: node, chain: component.chain, anchorIndex: index)
                if Self.hasNode(ofType: component.typeName, above: root) || roots.contains(where: { $0 === root }) { continue }
                roots.append(root)
            }
            if isSystem || roots.count <= limit { return (index, roots) }
            Self.log.append("\(component.name): anchor \(AttributeGraphTree.readable(component.chain[index]).prefix(70)) "
                            + "ambiguous, \(roots.count) nodes for \(component.instances)")
        }
        return nil
    }

    /// Chain types that can anchor a component. Plain `Text`, `_PaddingLayout`, `Spacer`… say nothing about
    /// *which* view this is, nor do the wrappers that show up everywhere.
    private static func anchorableIndices(_ chain: [String]) -> [Int] {
        chain.indices.filter { i in
            let type = chain[i]
            if isUninformative(type) { return false }
            return type.contains("<") || TypeNames.isAppType(type)
        }
    }

    /// A wrapper that shows up everywhere, or one built only of them:
    /// `ModifiedContent<PlaceholderContentView<OpacityTransition>, OpacityRendererEffect>` is in every view with an
    /// opacity transition.
    static func isUninformative(_ type: String) -> Bool {
        let base = TypeNames.base(of: TypeNames.shortName(of: type))
        if genericBases.contains(base) { return true }
        guard base == "ModifiedContent" || base == "_ConditionalContent" else { return false }
        let arguments = TypeNames.genericArguments(of: type)
        return !arguments.isEmpty && arguments.allSatisfy(isUninformative)
    }

    /// One of the two views is built from the other (`ChatTabItem`'s body is a `HolaTabItem`).
    private static func isNested(_ a: Component, _ b: Component) -> Bool {
        a.chain.contains { mentions($0, b.typeName) } || b.chain.contains { mentions($0, a.typeName) }
    }

    /// `type` is `name` or has it among its generic arguments (`ModifiedContent<…, Demo.CardStyle>`).
    private static func mentions(_ type: String, _ name: String) -> Bool {
        var start = type.startIndex
        while let range = type.range(of: name, range: start..<type.endIndex) {
            let before = range.lowerBound == type.startIndex ? nil : type[type.index(before: range.lowerBound)]
            let after = range.upperBound == type.endIndex ? nil : type[range.upperBound]
            let boundary: (Character?) -> Bool = { c in c.map { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") } ?? true }
            if boundary(before), boundary(after) { return true }
            start = range.upperBound
        }
        return false
    }

    /// Takes a synthetic node out again, its children in its place.
    private func unwrap(_ synthetic: RawDebugNode) {
        guard let parent = synthetic.parent, let index = parent.children.firstIndex(where: { $0 === synthetic }) else { return }
        parent.children.replaceSubrange(index...index, with: synthetic.children)
        synthetic.children.forEach { $0.parent = parent }
        synthetic.children = []
    }

    /// A node of `type` right above `node`, in the chain of single children that leads to it.
    private static func hasNode(ofType type: String, above node: RawDebugNode) -> Bool {
        var current = node.parent
        var below = node
        var steps = 0
        while let p = current, steps < 8 {
            if !p.isSynthetic, p.typeName == type { return true }
            guard p.children.count == 1, p.children[0] === below else { return false }
            below = p
            current = p.parent
            steps += 1
        }
        return false
    }

    /// The most specific chain type present in the `_ViewDebug` tree: fewest occurrences, then the most detailed
    /// type name.
    private func anchor(in chain: [String], anchorable: [Int]? = nil, byType: [String: [RawDebugNode]]) -> Int? {
        let candidates = (anchorable ?? Self.anchorableIndices(chain)).filter { i in
            guard let nodes = byType[chain[i]] else { return false }
            return !nodes.isEmpty
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
