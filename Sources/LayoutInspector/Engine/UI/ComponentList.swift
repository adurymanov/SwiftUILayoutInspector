#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// The components of a capture as a flat list: rows are filtered and sorted, the tree is walked through each row's
/// parent and children.
///
/// Apps wrap a screen in long chains of views and modifiers of one size (a presenter, a destination, a tab bar
/// modifier, the screen, its error state…). With wrappers folded, such a chain becomes one row: the innermost view
/// that isn't a `ViewModifier`, with the rest listed as its wrappers.
struct ComponentList {
    struct Item: Identifiable {
        let node: InspectorNode
        /// Folded into this row, outermost first.
        let wrappers: [InspectorNode]
        /// The node whose frame the row shows and outlines: the row's own, or, when that has no size (SwiftUI records
        /// some views under modifiers like `.task` at a zero-size helper), the nearest wrapper's.
        let target: InspectorNode
        var frame: CGRect { target.frame }
        let parent: Int?
        var children: [Int] = []
        let module: String
        let order: Int
        var id: Int { node.id }
    }

    let all: [Item]
    let folded: [Item]
    /// Where each host of the capture can show anything, in `space`: see ``visibleRegions(of:in:)``.
    let regions: [ObjectIdentifier: CGRect]

    /// `space`: the view the node frames are in; without it, Visible checks only the frames.
    init(_ capture: InspectorCapture?, modifierTypes: Set<String> = [], space: UIView? = nil) {
        let tree = Tree(capture)
        func isModifier(_ node: InspectorNode) -> Bool {
            node.kind == .customModifier || modifierTypes.contains(node.typeName) || capture?.modifierTypes.contains(node.typeName) == true
                || Self.isModifierName(node.title)
        }
        all = Self.unfolded(tree)
        folded = Self.folded(tree, isModifier: isModifier)
        regions = space.map { Self.visibleRegions(of: capture?.swiftUIRoots.compactMap(\.anchor.view) ?? [], in: $0) } ?? [:]
    }

    /// The part of each host that is on screen: its frame cut by every view around it that clips (a scroll view, a
    /// container of tabs or pages), `.null` when nothing is left. A host at the same place as a later host of the
    /// same class shows nothing of its own: a tab bar draws its items twice, the selected look over the plain one.
    static func visibleRegions(of hosts: [UIView], in space: UIView) -> [ObjectIdentifier: CGRect] {
        var result: [ObjectIdentifier: CGRect] = [:]
        var frames: [(host: UIView, frame: CGRect)] = []
        for host in hosts where result[ObjectIdentifier(host)] == nil {
            var region = host.convert(host.bounds, to: space)
            var next = host.superview
            while let view = next, region.width > 0, region.height > 0 {
                if view.clipsToBounds || view is UIWindow { region = region.intersection(view.convert(view.bounds, to: space)) }
                next = view.superview
            }
            result[ObjectIdentifier(host)] = region.isNull || region.width < 0.5 || region.height < 0.5 ? .null : region
            frames.append((host, host.convert(host.bounds, to: space)))
        }
        // Only small hosts side by side in one container (items of a bar): a full-screen overlay host of the same class
        // over a screen hides nothing of it.
        let screen = space.bounds.area
        for entry in frames where entry.frame.area > 0 && entry.frame.area < screen / 4 {
            let covered = frames.contains { other in
                other.host !== entry.host && type(of: other.host) == type(of: entry.host) && other.frame.isClose(to: entry.frame)
                    && !other.host.isHidden && other.host.alpha > 0.01 && isBelow(entry.host, other.host, within: 4)
            }
            if covered { result[ObjectIdentifier(entry.host)] = .null }
        }
        return result
    }

    /// `view` is drawn before `other`: where their branches meet, at most `levels` up from `view`, `view`'s comes first.
    private static func isBelow(_ view: UIView, _ other: UIView, within levels: Int) -> Bool {
        var chain: [UIView] = []
        var next: UIView? = other
        while let current = next { chain.append(current); next = current.superview }
        var child = view
        var parent = view.superview
        var level = 0
        while let p = parent, level < levels {
            level += 1
            if let index = chain.firstIndex(where: { $0 === p }), index > 0,
               let a = p.subviews.firstIndex(where: { $0 === child }), let b = p.subviews.firstIndex(where: { $0 === chain[index - 1] }) {
                return a < b
            }
            child = p
            parent = p.superview
        }
        return false
    }

    /// Components and the components nearest below each, in screen order.
    private struct Tree {
        var roots: [InspectorNode] = []
        var children: [ObjectIdentifier: [InspectorNode]] = [:]

        init(_ capture: InspectorCapture?) {
            func visit(_ node: InspectorNode, under parent: InspectorNode?) {
                var parent = parent
                if node.kind == .component || node.kind == .customModifier {
                    if let parent { children[ObjectIdentifier(parent), default: []].append(node) } else { roots.append(node) }
                    parent = node
                }
                node.children.forEach { visit($0, under: parent) }
            }
            capture?.swiftUIRoots.forEach { visit($0, under: nil) }
        }

        func children(of node: InspectorNode) -> [InspectorNode] { children[ObjectIdentifier(node)] ?? [] }
    }

    private static func unfolded(_ tree: Tree) -> [Item] {
        var items: [Item] = []
        func add(_ node: InspectorNode, parent: Int?) {
            let index = items.count
            items.append(Item(node: node, wrappers: [], target: node, parent: parent, module: TypeNames.module(of: node.typeName), order: index))
            if let parent { items[parent].children.append(index) }
            tree.children(of: node).forEach { add($0, parent: index) }
        }
        tree.roots.forEach { add($0, parent: nil) }
        return items
    }

    private static func folded(_ tree: Tree, isModifier: (InspectorNode) -> Bool) -> [Item] {
        var items: [Item] = []
        // Presenters and controller containers (a sheet or alert host, a `UIViewControllerRepresentable`) the size of
        // their parent with nothing of their own to show: wrappers of the parent rather than rows.
        // Only presenters and controller hosts by name: a map or a web view the size of its parent is content.
        func isEmpty(_ node: InspectorNode) -> Bool {
            tree.children(of: node).isEmpty && !hasContent(node) && Self.isPresenter(node)
        }
        /// No components inside but modifiers.
        func isLeaf(_ node: InspectorNode) -> Bool {
            tree.children(of: node).allSatisfy { isModifier($0) && isLeaf($0) }
        }
        // Inside a component, a leaf that draws nothing the capture sees (a touch catcher, a size reader, an empty
        // overlay) or a single text (a design system's text style) is part of the component around it rather than a
        // row. A leaf named for platform content (a player, a map) is content, though the capture can't see into it;
        // a leaf with more than one text (a row of a list) is a component of its own.
        func isPlumbing(_ child: InspectorNode) -> Bool {
            guard isLeaf(child) else { return false }
            let drawn = Self.drawn(in: child)
            if drawn.isEmpty { return !Self.isPresenter(child) && !Self.isPlatformContentName(child.title) }
            return drawn.count == 1 && drawn[0].kind == .text
        }
        func isHollow(_ child: InspectorNode, in parent: InspectorNode) -> Bool {
            (isEmpty(child) && sameFrame(parent, child)) || isPlumbing(child)
        }
        /// A folded child with the modifiers inside it.
        func withInsides(_ node: InspectorNode) -> [InspectorNode] { [node] + tree.children(of: node).flatMap(withInsides) }
        func children(of node: InspectorNode) -> (kept: [InspectorNode], hollow: [InspectorNode]) {
            let all = tree.children(of: node)
            let hollow = all.filter { isHollow($0, in: node) }
            return (all.filter { child in !hollow.contains { $0 === child } }, hollow.flatMap(withInsides))
        }
        func add(_ node: InspectorNode, parent: Int?, absorbing: [InspectorNode] = []) {
            var chain = [node]
            var hollow = absorbing
            while let last = chain.last, case let below = children(of: last), below.kept.count == 1,
                  sameFrame(last, below.kept[0]) || (isDegenerate(below.kept[0]) && !tree.children(of: below.kept[0]).isEmpty) {
                hollow += below.hollow
                chain.append(below.kept[0])
            }
            let innermost = chain[chain.count - 1]
            let below = children(of: innermost)
            hollow += below.hollow
            guard let row = chain.last(where: { !isModifier($0) && TypeNames.isAppType($0.typeName) }) ?? chain.last(where: { !isModifier($0) }) else {
                // Only modifiers, around views of other sizes: not a row, their views belong to the parent.
                below.kept.forEach { add($0, parent: parent) }
                return
            }
            let index = items.count
            let position = chain.firstIndex { $0 === row } ?? 0
            let target = isDegenerate(row) ? (chain[..<position].last { !isDegenerate($0) } ?? row) : row
            items.append(Item(node: row, wrappers: chain.filter { $0 !== row } + hollow, target: target, parent: parent,
                              module: TypeNames.module(of: row.typeName), order: index))
            if let parent { items[parent].children.append(index) }
            below.kept.forEach { add($0, parent: index) }
        }
        // At the top there is no parent to fold into: an empty root goes with a root of its size that has content.
        let roots = tree.roots
        let hollowRoots = roots.filter { root in isEmpty(root) && roots.contains { $0 !== root && !isEmpty($0) && sameFrame($0, root) } }
        var absorbed = Set<ObjectIdentifier>()
        for root in roots where !hollowRoots.contains(where: { $0 === root }) {
            let mine = hollowRoots.filter { !absorbed.contains(ObjectIdentifier($0)) && sameFrame(root, $0) }
            mine.forEach { absorbed.insert(ObjectIdentifier($0)) }
            add(root, parent: nil, absorbing: mine)
        }
        return items
    }

    /// Named as a `ViewModifier`: also folded as one, for the modifiers neither the graph nor the capture's trees tell.
    static func isModifierName(_ title: String) -> Bool {
        title.hasSuffix("Modifier")
    }

    static func isPresenter(_ node: InspectorNode) -> Bool {
        let name = node.title
        return ["Controller", "Presenter", "Presentation", "Modal", "Coordinator", "Router"].contains { name.contains($0) }
    }

    /// Anything drawn inside: text, an image, a shape or color, a control. Platform views alone (a controller's host)
    /// don't count.
    static func hasContent(_ node: InspectorNode) -> Bool {
        node.first { $0 !== node && [.text, .image, .shape, .color, .control, .divider].contains($0.kind) } != nil
    }

    /// What is drawn inside: texts, images, shapes, colors, controls, dividers, platform views.
    static func drawn(in node: InspectorNode) -> [InspectorNode] {
        var result: [InspectorNode] = []
        node.forEach { if $0 !== node, [.text, .image, .shape, .color, .control, .divider, .platform].contains($0.kind) { result.append($0) } }
        return result
    }

    /// Named for content the capture can't see into: a `UIViewRepresentable`, a player, a map, a web view.
    static func isPlatformContentName(_ title: String) -> Bool {
        ["Representable", "Player", "Video", "Camera", "Map", "Web"].contains { title.contains($0) }
    }

    static func isDegenerate(_ node: InspectorNode) -> Bool {
        node.frame.isNull || node.frame.width < 0.5 || node.frame.height < 0.5
    }

    static func sameFrame(_ a: InspectorNode, _ b: InspectorNode) -> Bool {
        let fa = a.anchor.rect, fb = b.anchor.rect
        guard a.anchor.view === b.anchor.view else { return a.frame.isClose(to: b.frame) }
        return fa.isClose(to: fb)
    }

    func items(folded isFolded: Bool) -> [Item] { isFolded ? folded : all }

    // MARK: - Filtering

    struct Filter: Codable, Equatable {
        var visibleOnly = true
        var hidesWrappers = true
        var appTypesOnly = true
        var rerenderedOnly = false
        var statefulOnly = false
        var module: String?
        var sort: Sort = .screen

        init(visibleOnly: Bool = true, hidesWrappers: Bool = true, appTypesOnly: Bool = true, rerenderedOnly: Bool = false,
             statefulOnly: Bool = false, module: String? = nil, sort: Sort = .screen) {
            self.visibleOnly = visibleOnly
            self.hidesWrappers = hidesWrappers
            self.appTypesOnly = appTypesOnly
            self.rerenderedOnly = rerenderedOnly
            self.statefulOnly = statefulOnly
            self.module = module
            self.sort = sort
        }

        // Missing keys and unknown values fall back to the defaults, so a saved filter survives new options.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Filter()
            visibleOnly = (try? c.decodeIfPresent(Bool.self, forKey: .visibleOnly)) ?? d.visibleOnly
            hidesWrappers = (try? c.decodeIfPresent(Bool.self, forKey: .hidesWrappers)) ?? d.hidesWrappers
            appTypesOnly = (try? c.decodeIfPresent(Bool.self, forKey: .appTypesOnly)) ?? d.appTypesOnly
            rerenderedOnly = (try? c.decodeIfPresent(Bool.self, forKey: .rerenderedOnly)) ?? d.rerenderedOnly
            statefulOnly = (try? c.decodeIfPresent(Bool.self, forKey: .statefulOnly)) ?? d.statefulOnly
            module = (try? c.decodeIfPresent(String.self, forKey: .module)) ?? nil
            sort = (try? c.decodeIfPresent(Sort.self, forKey: .sort)) ?? d.sort
        }

        enum Sort: String, Codable, CaseIterable {
            case screen, rerenders, area

            var title: String {
                switch self {
                case .screen: "Screen order"
                case .rerenders: "Re-renders"
                case .area: "Area"
                }
            }
        }
    }

    struct Context {
        var bounds: CGRect = .infinite
        var counts: RenderCounts?
        /// Components with `@State` or `@Binding`; `nil` until read.
        var stateful: Set<Int>?
        var query = ""
        /// A point picked on screen: only the components containing it, smallest first.
        var point: CGPoint?
    }

    func rows(_ filter: Filter, _ context: Context) -> [Item] {
        let query = context.query.trimmingCharacters(in: .whitespaces)
        var rows = items(folded: filter.hidesWrappers).filter { item in
            let node = item.node
            if let point = context.point, !item.frame.contains(point) { return false }
            if filter.visibleOnly, !Self.isVisible(item.target, in: context.bounds) || !isInRegion(item.target) { return false }
            if filter.appTypesOnly, !TypeNames.isAppType(node.typeName) { return false }
            // A row stands for its folded wrappers too.
            let members = [node] + item.wrappers
            if filter.rerenderedOnly, !members.contains(where: { (context.counts?.byNode[$0.id]?.count ?? 0) > 0 }) { return false }
            if filter.statefulOnly, !members.contains(where: { context.stateful?.contains($0.id) == true }) { return false }
            if let module = filter.module, !members.contains(where: { TypeNames.module(of: $0.typeName) == module }) { return false }
            if !query.isEmpty, !members.contains(where: { member in
                member.title.localizedCaseInsensitiveContains(query) || member.typeName.localizedCaseInsensitiveContains(query)
                    || TypeNames.module(of: member.typeName).localizedCaseInsensitiveContains(query)
            }) { return false }
            return true
        }
        if context.point != nil {
            rows.sort { $0.frame.area < $1.frame.area }
            return rows
        }
        switch filter.sort {
        case .screen:
            rows.sort { a, b in
                let fa = a.frame, fb = b.frame
                if fa.isNull != fb.isNull { return !fa.isNull }
                if abs(fa.minY - fb.minY) > 0.5 { return fa.minY < fb.minY }
                if abs(fa.minX - fb.minX) > 0.5 { return fa.minX < fb.minX }
                return a.order < b.order
            }
        case .rerenders:
            rows.sort { (Self.hottest($0, context.counts), -$0.order) > (Self.hottest($1, context.counts), -$1.order) }
        case .area:
            rows.sort { ($0.frame.area, -$0.order) > ($1.frame.area, -$1.order) }
        }
        return rows
    }

    /// Counts of the modifiers folded into a row, by their names: an `Animatable` modifier (a shimmer) runs its `body`
    /// on every frame of its animation, while the view it is applied to doesn't. A count shared with other views shows
    /// as one (`Σ14/2`): the modifier isn't a row of its own.
    static func wrapperRenders(of item: Item, counts: RenderCounts?) -> [(title: String, entry: RenderCounts.Entry)] {
        guard let counts else { return [] }
        return item.wrappers.compactMap { wrapper in
            counts.byNode[wrapper.id].flatMap { $0.count > 0 ? (wrapper.title, $0) : nil }
        }
    }

    /// The highest count of a row: its own or one of its folded modifiers'.
    static func hottest(_ item: Item, _ counts: RenderCounts?) -> Int {
        ([counts?.byNode[item.node.id]?.count ?? 0] + wrapperRenders(of: item, counts: counts).filter { $0.entry.instances == 1 }.map(\.entry.count)).max() ?? 0
    }

    /// A row of the list: one component, or a run of siblings of one type ("Row ×14") that opens with a tap.
    enum Entry: Identifiable {
        case item(Item)
        case group(key: String, items: [Item])
        /// Above an opened group: folds it again.
        case close(key: String, items: [Item])

        var id: String {
            switch self {
            case let .item(item): "\(item.id)"
            case let .group(key, _): key
            case let .close(key, _): "close:" + key
            }
        }
    }

    /// Three or more siblings of one type (rows of a list, cards of a grid, tab items) become one group unless
    /// `expanded` holds its key; a folded group hides what is inside its members too. The group takes the place of its
    /// first member: in screen order the members' insides come between them, so siblings are found by their parent,
    /// not by being next to each other. Only in screen order without a picked point or a search.
    func entries(_ rows: [Item], filter: Filter, context: Context, expanded: Set<String>, selected: Int? = nil) -> [Entry] {
        guard filter.sort == .screen, context.point == nil, context.query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return rows.map(Entry.item)
        }
        let items = items(folded: filter.hidesWrappers)
        struct Siblings: Hashable { let parent: Int?; let type: String }
        var runs: [Siblings: [Item]] = [:]
        for row in rows { runs[Siblings(parent: row.parent, type: row.node.typeName), default: []].append(row) }
        runs = runs.filter { $0.value.count >= 3 }
        // A group with the selected component in it (or inside one of its members) stays open.
        var selectedPath = Set<Int>()
        if let selected, let start = items.firstIndex(where: { $0.node.id == selected || $0.wrappers.contains { $0.id == selected } }) {
            selectedPath.insert(selected)
            var index = start
            while let parent = items[index].parent { selectedPath.insert(items[parent].node.id); index = parent }
        }
        var keys: [Siblings: String] = [:]
        var usedKeys = Set<String>()
        var folded = Set<Int>()   // members of groups shown folded
        for (siblings, run) in runs.sorted(by: { $0.value[0].order < $1.value[0].order }) {
            // Stable across captures: the parent's type and the run's type.
            let base = "\(siblings.parent.map { items[$0].node.typeName } ?? "-"):\(siblings.type)"
            var key = base
            var n = 2
            while usedKeys.contains(key) { key = "\(base)#\(n)"; n += 1 }
            usedKeys.insert(key)
            keys[siblings] = key
            if !expanded.contains(key), !run.contains(where: { selectedPath.contains($0.node.id) }) { folded.formUnion(run.map(\.node.id)) }
        }
        func isInsideFolded(_ row: Item) -> Bool {
            var next = row.parent
            while let index = next {
                if folded.contains(items[index].node.id) { return true }
                next = items[index].parent
            }
            return false
        }
        var result: [Entry] = []
        var started = Set<Siblings>()
        for row in rows where !isInsideFolded(row) {
            let siblings = Siblings(parent: row.parent, type: row.node.typeName)
            if let key = keys[siblings], let run = runs[siblings] {
                let first = started.insert(siblings).inserted
                if folded.contains(row.node.id) {
                    if first { result.append(.group(key: key, items: run)) }
                    continue
                }
                if first, expanded.contains(key) { result.append(.close(key: key, items: run)) }
            }
            result.append(.item(row))
        }
        return result
    }

    /// Lies in the part of its host that is on screen (always, when the regions aren't known).
    private func isInRegion(_ node: InspectorNode) -> Bool {
        guard let host = node.path.first?.anchor.view, let region = regions[ObjectIdentifier(host)] else { return true }
        let shown = node.frame.intersection(region)
        return !shown.isNull && shown.width >= 0.5 && shown.height >= 0.5
    }

    /// Has a size, is on screen and isn't hidden by a presentation above it.
    static func isVisible(_ node: InspectorNode, in bounds: CGRect) -> Bool {
        let frame = node.frame
        return !frame.isNull && frame.width >= 0.5 && frame.height >= 0.5 && frame.intersects(bounds)
    }

    /// Modules of the screen's components, the app's first.
    var modules: [String] {
        Array(Set(all.map(\.module))).sorted { a, b in
            let appA = TypeNames.isAppType(a + ".X"), appB = TypeNames.isAppType(b + ".X")
            return appA != appB ? appA : a < b
        }
    }

    /// Parents of `item` in `items`, outermost first.
    func parents(of item: Item, in items: [Item]) -> [Item] {
        var result: [Item] = []
        var current = item.parent
        while let index = current { result.insert(items[index], at: 0); current = items[index].parent }
        return result
    }

    func text(_ rows: [Item], in items: [Item], counts: RenderCounts?) -> String {
        var lines = ["# Components – \(rows.count)"]
        for row in rows {
            var line = "\(row.node.title)  @ \(row.frame.frameLabel)"
            if let parent = row.parent { line += "  in \(items[parent].node.title)" }
            if !row.wrappers.isEmpty { line += "  +\(row.wrappers.count) wrappers" }
            if let entry = counts?.byNode[row.node.id], entry.count > 0 { line += "  renders \(entry.label)" }
            for (title, entry) in Self.wrapperRenders(of: row, counts: counts) { line += "  \(title) renders \(entry.label)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func isClose(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        if isNull || other.isNull { return isNull && other.isNull }
        return abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

#endif
