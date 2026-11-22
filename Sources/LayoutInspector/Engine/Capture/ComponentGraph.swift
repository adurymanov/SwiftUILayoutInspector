#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit
internal import LayoutInspectorAttributeGraph

/// One app view as AttributeGraph holds it.
struct GraphView {
    /// The graph nodes its tree element owns; its `body` is one of them.
    let nodes: [UInt32]
    /// The node that holds the view's value (the struct its parent built).
    let valueNode: UInt32
    let type: Any.Type
    /// The box SwiftUI recorded for the first view its `body` produced (`nil` when none is recorded, e.g. off screen).
    var frame: CGRect?
    /// The boxes of all the views its `body` produced, together.
    var bounds: CGRect?
    /// The nearest app view around this one, as an index into the list it came in (``ComponentGraph/Forest/views``).
    var parent: Int?
    /// The hosting view whose tree holds it.
    weak var host: UIView?
}

/// Finds the AttributeGraph views behind the components of a capture.
///
/// The graph often holds more views of a type than the capture shows (rows of a lazy stack off screen, hidden copies),
/// and lists them in an order of its own. Components are matched from the outside in: a component's view is looked for
/// only inside the view of the nearest component around it that was already told apart (or in its own host at the top),
/// since the graph nests app views the way the capture nests components. That alone tells apart the copies of a card's
/// insides, which SwiftUI records at the same place in every card (`geometryGroup`), views whose `body` draws nothing,
/// and the same view in two hosts. Inside that scope a view is tied to the box SwiftUI recorded for the first view its
/// `body` produced: the element of a produced view has a value that resolves (through `AGGraphGetIndirectAttribute`) to
/// the `body` node that built it, and the capture keeps the same recorded box for each component. Then the texts the
/// view was built with; components left over share their views' total.
enum ComponentGraph {
    struct Match {
        /// One view when the component was told apart, otherwise the views of its type it couldn't be told from.
        let views: [GraphView]
        var isExact: Bool { views.count == 1 }
    }

    /// Every app view of a window's hosts, each once, with the view around it.
    struct Forest {
        var views: [GraphView] = []
        var byType: [String: [Int]] = [:]
    }

    /// Matches for the components of `capture`, by ``InspectorNode/id``. Empty when the graph can't be reached (iOS 18).
    /// Worked out once per capture.
    static func match(_ capture: InspectorCapture) -> [Int: Match] {
        if let cached = matchCache, cached.capture === capture { return cached.result }
        let result = freshMatch(capture)
        matchCache = (capture, result)
        return result
    }

    private static var matchCache: (capture: InspectorCapture, result: [Int: Match])?
    private static var forestCache: (capture: InspectorCapture, result: Forest)?

    private struct Scope: Hashable {
        /// The view of the nearest component around that was told apart.
        var around: Int?
        var host: ObjectIdentifier?
        var type: String
    }

    private static func freshMatch(_ capture: InspectorCapture) -> [Int: Match] {
        let forest = forest(in: capture)
        guard !forest.views.isEmpty else { return [:] }
        // Components by how many components are around them: the outer ones are matched first.
        var levels: [[InspectorNode]] = []
        func walk(_ node: InspectorNode, level: Int) {
            var inner = level
            if node.kind == .component, forest.byType[node.typeName] != nil {
                if levels.count <= level { levels.append([]) }
                levels[level].append(node)
                inner += 1
            }
            for child in node.children { walk(child, level: inner) }
        }
        for root in capture.swiftUIRoots { walk(root, level: 0) }

        var exact: [Int: Int] = [:]
        var owner: [Int: Int] = [:]
        var used = Set<Int>()
        var result: [Int: Match] = [:]
        /// The views of the components around `node` that were told apart, nearest first.
        func around(_ node: InspectorNode) -> [Int] {
            var result: [Int] = []
            var next = node.parent
            while let parent = next {
                if let view = exact[parent.id] { result.append(view) }
                next = parent.parent
            }
            return result
        }
        for level in levels {
            var groups: [Scope: [InspectorNode]] = [:]
            var order: [Scope] = []
            for node in level {
                let outer = around(node).first
                let scope = Scope(around: outer, host: outer == nil ? node.path.first?.anchor.view.map(ObjectIdentifier.init) : nil, type: node.typeName)
                if groups[scope] == nil { order.append(scope) }
                groups[scope, default: []].append(node)
            }
            // Scoped groups first: a group matched across the whole window takes only what they leave.
            for scope in order.sorted(by: { ($0.around == nil ? 1 : 0) < ($1.around == nil ? 1 : 0) }) {
                let nodes = groups[scope]!
                let outer = around(nodes[0])
                // A view inside a view already told apart belongs to that view's component: only a component inside it
                // can be that view. Of the views left, the ones inside the nearest component around come first.
                var tiers: [Int: [Int]] = [:]
                for view in forest.byType[scope.type] ?? [] where !used.contains(view) {
                    var next = forest.views[view].parent
                    while let index = next, owner[index] == nil { next = forest.views[index].parent }
                    let tier = next.map { outer.firstIndex(of: $0) ?? -1 } ?? outer.count
                    if tier >= 0 { tiers[tier, default: []].append(view) }
                }
                // Inside the nearest component around first. AttributeGraph doesn't always nest views the way the
                // capture does (a `TimelineView`'s content sits under the view that placed it, and a scroll view's
                // content in a navigation stack is a tree of its own, outside the screen's view), so then inside the
                // next component out, and at last outside all of them, in the component's own host first. Away from
                // the nearest component the views are told apart only while no other component of the type waits
                // in the same scope; otherwise they share one total.
                guard let tier = tiers.keys.min(), var candidates = tiers[tier] else { continue }
                if tier == outer.count, let host = nodes[0].path.first?.anchor.view {
                    let own = candidates.filter { forest.views[$0].host === host }
                    if !own.isEmpty { candidates = own }
                }
                var mayTellApart = true
                if tier > 0, tier < outer.count {
                    let scopeView = outer[tier]
                    mayTellApart = !level.contains { other in
                        other.typeName == scope.type && result[other.id] == nil && !nodes.contains { $0 === other }
                            && around(other).contains(scopeView)
                    }
                }
                let assigned = mayTellApart ? assign(nodes, candidates, forest)
                    : candidates.count > 1 ? nodes.map { ($0, candidates) } : []
                for (node, views) in assigned {
                    result[node.id] = Match(views: views.map { forest.views[$0] })
                    if views.count == 1 { exact[node.id] = views[0]; owner[views[0]] = node.id }
                    used.formUnion(views)
                }
            }
        }
        if ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_LOG"] != nil {
            logDiag(levels: levels, forest: forest, result: result)
        }
        return result
    }

    /// Ties `nodes` (components of one type in one scope) to `candidates` (views of that type there): one each when
    /// there is one of both, then by the recorded box, then by the texts; the rest share what is left.
    private static func assign(_ nodes: [InspectorNode], _ candidates: [Int], _ forest: Forest) -> [(InspectorNode, [Int])] {
        if nodes.count == 1, candidates.count == 1, fits(nodes[0], forest.views[candidates[0]]) { return [(nodes[0], candidates)] }
        var left = candidates
        var result: [(InspectorNode, [Int])] = []
        // By the recorded box. Two views with one box (a copy at the same place) are left to the texts.
        var byText: [InspectorNode] = []
        for node in nodes.sorted(by: { $0.id < $1.id }) {
            let boxed = node.recordedFrame.map { box in left.indices.filter { forest.views[left[$0]].frame.map { $0.isClose(to: box) } ?? false } } ?? []
            if boxed.count == 1 {
                result.append((node, [left.remove(at: boxed[0])]))
            } else {
                byText.append(node)
            }
        }
        guard !byText.isEmpty, !left.isEmpty else { return result }
        // As many components as views here, and all but one paired by their boxes: the last two belong together.
        if nodes.count == candidates.count, byText.count == 1, left.count == 1, fits(byText[0], forest.views[left[0]]) {
            return result + [(byText[0], left)]
        }
        var unmatched: [InspectorNode] = []
        // By text: the view whose own strings cover most of the component's texts, when that view is the only one.
        var strings = left.map { Self.strings(of: forest.views[$0]) }
        for node in byText {
            let texts = Self.texts(in: node)
            guard !texts.isEmpty else { unmatched.append(node); continue }
            let overlaps = strings.indices.map { fits(node, forest.views[left[$0]]) ? strings[$0].intersection(texts).count : 0 }
            let best = overlaps.max() ?? 0
            let tied = overlaps.indices.filter { overlaps[$0] == best }
            if best > 0, tied.count == 1 {
                result.append((node, [left.remove(at: tied[0])]))
                strings.remove(at: tied[0])
            } else if best > 0 {
                // Built with the same texts (a hidden copy, two identical labels): one total for those views.
                result.append((node, tied.map { left[$0] }))
            } else {
                unmatched.append(node)
            }
        }
        guard !unmatched.isEmpty, !left.isEmpty else { return result }
        // Nothing tells the rest apart, and the graph's order isn't the screen's: one total for them, rather than
        // counts that look exact on the wrong view. A view that can't be this one isn't counted in, and a component
        // that no view can be gets no count.
        for node in unmatched {
            let fitting = left.filter { fits(node, forest.views[$0]) }
            if fitting.count > 1 { result.append((node, fitting)) }
        }
        return result
    }

    /// The view can be the component: the component's recorded box lies on the views its `body` produced. The capture
    /// and the graph don't always take the same first view (a stack or its first child, a safe area inset before the
    /// content), but the box is always on one of them; it isn't when the capture named a node after a view that is
    /// somewhere else.
    private static func fits(_ node: InspectorNode, _ view: GraphView) -> Bool {
        guard let box = node.recordedFrame, let bounds = view.bounds, box.width > 0, box.height > 0, bounds.width > 0, bounds.height > 0 else {
            return true
        }
        return box.insetBy(dx: -1, dy: -1).intersects(bounds)
    }

    /// `LAYOUT_INSPECTOR_LOG`: each type with components that got no count of their own, with the boxes on both sides.
    private static func logDiag(levels: [[InspectorNode]], forest: Forest, result: [Int: Match]) {
        func box(_ f: CGRect?) -> String { f.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none" }
        var byType: [String: [InspectorNode]] = [:]
        for node in levels.joined() { byType[node.typeName, default: []].append(node) }
        for (type, nodes) in byType.sorted(by: { $0.key < $1.key }) {
            let open = nodes.filter { result[$0.id].map { !$0.isExact } ?? true }
            guard !open.isEmpty else { continue }
            let views = (forest.byType[type] ?? []).map { forest.views[$0] }
            NSLog("%@", "LayoutInspector match: \(type.prefix(120)): \(nodes.count) components, \(open.count) without a count of their own "
                  + "(\(open.filter { result[$0.id] == nil }.count) without any), \(views.count) views in the graph; components "
                  + open.prefix(6).map { box($0.recordedFrame) + " in " + ($0.parent?.title ?? "-") }.joined(separator: "; ")
                  + "; views " + views.prefix(6).map { box($0.frame) }.joined(separator: "; "))
        }
    }

    /// The strings of the texts inside a component.
    static func texts(in node: InspectorNode) -> Set<String> {
        var result = Set<String>()
        node.forEach { if let string = $0.info.text?.string, !string.isEmpty { result.insert(string) } }
        return result
    }

    /// The strings a view was built with, two levels deep (`title`, `line.title`), and the numbers as text: a text
    /// often shows one (`"$\(amount)"`).
    static func strings(of view: GraphView) -> Set<String> {
        guard let value = value(of: view) else { return [] }
        var result = Set<String>()
        func collect(_ value: Any, depth: Int) {
            for child in Mirror(reflecting: value).children {
                switch child.value {
                case let string as String: if !string.isEmpty { result.insert(string) }
                // Small numbers ("0", "1") are in every badge and index: they would tie a view to the wrong texts.
                case let number as any BinaryInteger where !(-9...9).contains(Int(number)): result.insert("\(number)")
                default: if depth < 2 { collect(child.value, depth: depth + 1) }
                }
            }
        }
        collect(value, depth: 0)
        // Texts that show a number with a prefix or suffix ("$40", "40 %") match by the number.
        return result.union(result.compactMap { Int($0) == nil ? nil : $0 }.flatMap { [$0, "$\($0)", "\($0) %"] })
    }

    /// App views of every hosting view of the capture's window: the view types of a screen can be declared in the
    /// AttributeGraph tree of another host (the root host around a navigation stack).
    static func forest(in capture: InspectorCapture) -> Forest {
        if let cached = forestCache, cached.capture === capture { return cached.result }
        var hosts: [UIView] = []
        for root in capture.swiftUIRoots {
            guard let host = root.anchor.view else { continue }
            let all = host.window.map { LayoutCapture.visibleHostingViews(in: $0, excluding: []) } ?? [host]
            for candidate in all where !hosts.contains(where: { $0 === candidate }) { hosts.append(candidate) }
        }
        var forest = Forest()
        var byValue: [UInt32: Int] = [:]
        for host in hosts {
            let (views, names) = tree(of: host)
            // A tree can include a nested host's elements: each view once, in the first tree that has it.
            var local: [Int: Int] = [:]
            for (index, view) in views.enumerated() {
                if let known = byValue[view.valueNode] { local[index] = known; continue }
                var view = view
                view.parent = view.parent.flatMap { local[$0] }
                local[index] = forest.views.count
                byValue[view.valueNode] = forest.views.count
                forest.byType[names[index], default: []].append(forest.views.count)
                forest.views.append(view)
            }
        }
        forestCache = (capture, forest)
        return forest
    }

    /// Types of the capture's app views that are `ViewModifier`s, by full type name.
    static func modifierTypes(in capture: InspectorCapture) -> Set<String> {
        let forest = forest(in: capture)
        return Set(forest.byType.compactMap { name, views in views.first.map { forest.views[$0].type is any ViewModifier.Type } == true ? name : nil })
    }

    /// Every app view under `host`, by type, with the box of the first view its `body` produced.
    static func views(of host: UIView) -> [String: [GraphView]] {
        let (views, names) = tree(of: host)
        var result: [String: [GraphView]] = [:]
        for (name, view) in zip(names, views) { result[name, default: []].append(view) }
        return result
    }

    /// Every app view under `host` in the order of its tree, each with the view around it (an index into the same list),
    /// and the box of the first view its `body` produced.
    static func tree(of host: UIView) -> (views: [GraphView], names: [String]) {
        guard RenderProfiler.isAvailable, let subgraph = AttributeGraphTree.rootSubgraph(of: host),
              let root = LIAGSubgraphGetTreeRoot(subgraph) else { return ([], []) }
        var views: [GraphView] = []
        var names: [String] = []
        var byNode: [UInt32: Int] = [:]
        var children = [LIAGTreeElement?](repeating: nil, count: 1024)
        // Generous: a view's body node can come after every node of a long modifier chain.
        var nodes = [UInt32](repeating: 0, count: 1024)
        func elements(of element: LIAGTreeElement) -> [LIAGTreeElement] {
            let n = Int(children.withUnsafeMutableBufferPointer { LIAGTreeElementGetChildren(element, $0.baseAddress!, Int32($0.count)) })
            return children[0..<n].compactMap { $0 }.reversed()
        }
        // The app's views, the nodes they own and the view around each.
        func collect(_ element: LIAGTreeElement, around: Int?, depth: Int) {
            var inner = around
            if let meta = LIAGTreeElementGetType(element) {
                let type = unsafeBitCast(meta, to: Any.Type.self)
                let name = TypeNames.qualifiedName(of: type)
                if TypeNames.isAppType(name) {
                    let n = Int(nodes.withUnsafeMutableBufferPointer { LIAGTreeElementGetNodes(element, $0.baseAddress!, Int32($0.count)) })
                    let owned = Array(nodes[0..<max(n, 0)])
                    for node in owned { byNode[node] = views.count }
                    // Modifiers often own no nodes of their own; they are listed all the same.
                    views.append(GraphView(nodes: owned, valueNode: LIAGTreeElementGetValue(element), type: type, parent: around, host: host))
                    names.append(name)
                    inner = views.count - 1
                }
            }
            guard depth < 400 else { return }
            for child in elements(of: element) { collect(child, around: inner, depth: depth + 1) }
        }
        collect(root, around: nil, depth: 0)
        // The views their bodies produced (elements of flags 0, whose value resolves to a body node), and the first box
        // recorded at or below each, as `_ViewDebug` gives the capture.
        func place(_ element: LIAGTreeElement, waiting: [Int], depth: Int) {
            var waiting = waiting
            if LIAGTreeElementGetFlags(element) == 0 {
                let source = LIAGGraphGetIndirectAttribute(LIAGTreeElementGetValue(element))
                if let index = byNode[source], !waiting.contains(index) { waiting.append(index) }
                if !waiting.isEmpty, let box = recordedBox(of: element) {
                    for index in waiting {
                        if views[index].frame == nil { views[index].frame = box }
                        views[index].bounds = views[index].bounds.map { $0.union(box) } ?? box
                    }
                    waiting = []
                }
            }
            guard depth < 400 else { return }
            for child in elements(of: element) { place(child, waiting: waiting, depth: depth + 1) }
        }
        place(root, waiting: [], depth: 0)
        return (views, names)
    }

    private static func recordedBox(of element: LIAGTreeElement) -> CGRect? {
        var position: UInt32 = 0, size: UInt32 = 0
        var positionType: UnsafeRawPointer?, sizeType: UnsafeRawPointer?
        guard LIAGTreeElementGetGeometry(element, &position, &positionType, &size, &sizeType),
              let positionType, let sizeType else { return nil }
        func read<T>(_ attribute: UInt32, _ type: UnsafeRawPointer, as _: T.Type) -> T? {
            guard let value = LIAGGraphGetValue(attribute, type) else { return nil }
            func size<V>(_: V.Type) -> Int { MemoryLayout<V>.size }
            // `ViewOrigin` starts with its point, `ViewSize` with its size.
            guard _openExistential(unsafeBitCast(type, to: Any.Type.self), do: size) >= MemoryLayout<T>.size else { return nil }
            return value.loadUnaligned(as: T.self)
        }
        guard let origin = read(position, positionType, as: CGPoint.self), let extent = read(size, sizeType, as: CGSize.self) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The view's current value, as its parent built it. `nil` when the graph can't be read.
    static func value(of view: GraphView) -> Any? {
        let meta = unsafeBitCast(view.type, to: UnsafeRawPointer.self)
        guard let pointer = LIAGGraphGetValue(view.valueNode, meta) else { return nil }
        func load<T>(_: T.Type) -> Any { pointer.assumingMemoryBound(to: T.self).pointee }
        return _openExistential(view.type, do: load)
    }
}

#endif

