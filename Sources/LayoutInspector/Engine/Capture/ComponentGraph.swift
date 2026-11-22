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
    /// ``TypeNames/qualifiedName(of:)`` of `type`.
    let typeName: String
    /// The box SwiftUI recorded for the first view its `body` produced (`nil` when none is recorded, e.g. off screen).
    var frame: CGRect?
    /// The boxes of all the views its `body` produced, together.
    var bounds: CGRect?
    /// The nearest app view around this one, as an index into the list it came in (``ComponentGraph/Forest/views``).
    var parent: Int?
    /// The hosting view whose tree holds it.
    weak var host: UIView?
    /// Its index in ``ComponentGraph/Forest/hosts``.
    var hostIndex = 0
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
        var hosts: [UIView] = []
        var views: [GraphView] = []
        var byType: [String: [Int]] = [:]
        /// Whether each node of the views computes a `body`, worked out in the frame the node was read (a node read
        /// frames later may belong to a subgraph that went away). Empty when AttributeGraph can't tell by node.
        var isBody: [UInt32: Bool] = [:]
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

    /// The capture's components and the forest's views as plain values, and the components by their index there.
    static func input(_ capture: InspectorCapture, _ forest: Forest, withStrings: Bool = false) -> (MatchInput, [InspectorNode]) {
        var input = MatchInput()
        var nodes: [InspectorNode] = []
        func walk(_ node: InspectorNode, parent: Int?, host: Int?) {
            var inner = parent
            if node.kind == .component {
                inner = nodes.count
                nodes.append(node)
                input.components.append(MatchInput.Component(
                    id: node.id, type: node.typeName, parent: parent, host: host, box: node.recordedFrame?.values,
                    texts: Array(texts(in: node)).sorted(), frame: node.frame.isNull ? nil : node.frame.values))
            }
            for child in node.children { walk(child, parent: inner, host: host) }
        }
        for root in capture.swiftUIRoots {
            let host = root.anchor.view.flatMap { view in forest.hosts.firstIndex { $0 === view } }
            walk(root, parent: nil, host: host)
        }
        input.views = forest.views.map { view in
            MatchInput.View(type: view.typeName, parent: view.parent, host: view.hostIndex, frame: view.frame?.values,
                            bounds: view.bounds?.values, strings: withStrings ? Array(strings(of: view)).sorted() : nil)
        }
        return (input, nodes)
    }

    private static func freshMatch(_ capture: InspectorCapture) -> [Int: Match] {
        let forest = forest(in: capture)
        guard !forest.views.isEmpty else { return [:] }
        let (input, nodes) = input(capture, forest)
        var cache: [Int: Set<String>] = [:]
        let matcher = ComponentMatcher(input) { index in
            if let known = cache[index] { return known }
            let value = strings(of: forest.views[index])
            cache[index] = value
            return value
        }
        let assigned = matcher.run()
        var result: [Int: Match] = [:]
        for (index, views) in assigned { result[nodes[index].id] = Match(views: views.map { forest.views[$0] }) }
        if ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_LOG"] != nil {
            logDiag(nodes: nodes, forest: forest, result: result)
        }
        MatchRecorder.writeIfRequested(capture, forest)
        return result
    }

    /// `LAYOUT_INSPECTOR_LOG`: each type with components that got no count of their own, with the boxes on both sides.
    private static func logDiag(nodes: [InspectorNode], forest: Forest, result: [Int: Match]) {
        func box(_ f: CGRect?) -> String { f.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none" }
        var byType: [String: [InspectorNode]] = [:]
        for node in nodes where forest.byType[node.typeName] != nil { byType[node.typeName, default: []].append(node) }
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
        let builder = ForestBuilder(capture)
        while !builder.step() {}
        return builder.forest
    }

    /// The forest of `capture` when it was read already.
    static func cachedForest(of capture: InspectorCapture) -> Forest? {
        forestCache.flatMap { $0.capture === capture ? $0.result : nil }
    }

    /// Reads a capture's forest a host at a time (``step()``), so that a big app's hosts don't all take one frame.
    final class ForestBuilder {
        private weak var capture: InspectorCapture?
        private(set) var forest = Forest()
        private var next = 0
        private var byValue: [UInt32: Int] = [:]

        init(_ capture: InspectorCapture) {
            self.capture = capture
            var hosts: [UIView] = []
            for root in capture.swiftUIRoots {
                guard let host = root.anchor.view else { continue }
                let all = host.window.map { LayoutCapture.visibleHostingViews(in: $0, excluding: []) } ?? [host]
                for candidate in all where !hosts.contains(where: { $0 === candidate }) { hosts.append(candidate) }
            }
            forest.hosts = hosts
        }

        /// Reads the next host's tree. `true` when every host is read: the forest is then the capture's.
        func step() -> Bool {
            if next < forest.hosts.count {
                read(forest.hosts[next], index: next)
                next += 1
            }
            guard next >= forest.hosts.count else { return false }
            if let capture { forestCache = (capture, forest) }
            return true
        }

        private func read(_ host: UIView, index hostIndex: Int) {
            let (views, names) = tree(of: host)
            // A tree can include a nested host's elements: each view once, in the first tree that has it.
            var local: [Int: Int] = [:]
            for (index, view) in views.enumerated() {
                if let known = byValue[view.valueNode] { local[index] = known; continue }
                var view = view
                view.parent = view.parent.flatMap { local[$0] }
                view.hostIndex = hostIndex
                local[index] = forest.views.count
                byValue[view.valueNode] = forest.views.count
                forest.byType[names[index], default: []].append(forest.views.count)
                forest.views.append(view)
                for node in view.nodes { if let body = RenderProfiler.isBody(node) { forest.isBody[node] = body } }
            }
        }
    }

    /// Types of the capture's app views that are `ViewModifier`s, by full type name.
    static func modifierTypes(in capture: InspectorCapture, readingGraph: Bool = true) -> Set<String> {
        guard let forest = readingGraph ? forest(in: capture) : cachedForest(of: capture) else { return [] }
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
    static func tree(of host: UIView, checked: Bool = checksForest) -> (views: [GraphView], names: [String]) {
        guard RenderProfiler.isAvailable, let subgraph = AttributeGraphTree.rootSubgraph(of: host),
              let root = LIAGSubgraphGetTreeRoot(subgraph) else { return ([], []) }
        let attachments = AttributeGraphTree.subgraphAttachments(of: subgraph)
        let result = tree(root, host: host, attachments: attachments)
        if checked, attachments != nil {
            let full = tree(root, host: host, attachments: nil)
            let same = full.names == result.names && zip(full.views, result.views).allSatisfy { $0.frame == $1.frame && $0.parent == $1.parent }
            NSLog("%@", "LayoutInspector forest check: \(same ? "same" : "DIFFERENT") (\(result.views.count) views, \(full.views.count) with every subgraph looked up)")
        }
        return result
    }

    /// `LAYOUT_INSPECTOR_CHECK_FOREST`: reads each tree a second time the slow way and logs whether both agree.
    static let checksForest = ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_CHECK_FOREST"] != nil

    /// Whether each type is an app type, by its metadata: asked for every element of every tree.
    private static var appTypes: [UnsafeRawPointer: (name: String, isApp: Bool)] = [:]

    private static func tree(_ root: LIAGTreeElement, host: UIView, attachments: Set<UnsafeRawPointer>?) -> (views: [GraphView], names: [String]) {
        var views: [GraphView] = []
        var names: [String] = []
        var byNode: [UInt32: Int] = [:]
        var children = [LIAGTreeElement?](repeating: nil, count: 1024)
        // Generous: a view's body node can come after every node of a long modifier chain.
        var nodes = [UInt32](repeating: 0, count: 1024)
        // Every element once, in the order of the tree, with the element around it: the produced views are placed in a
        // second pass over this list, after every view's nodes are known.
        var elements: [LIAGTreeElement] = []
        var parents: [Int32] = []
        func collect(_ element: LIAGTreeElement, parent: Int32, around: Int?, depth: Int) {
            let index = Int32(elements.count)
            elements.append(element)
            parents.append(parent)
            var inner = around
            if let meta = LIAGTreeElementGetType(element) {
                let known = appTypes[meta] ?? {
                    let name = TypeNames.qualifiedName(of: unsafeBitCast(meta, to: Any.Type.self))
                    let entry = (name, TypeNames.isAppType(name))
                    appTypes[meta] = entry
                    return entry
                }()
                if known.isApp {
                    let n = Int(nodes.withUnsafeMutableBufferPointer { LIAGTreeElementGetNodes(element, $0.baseAddress!, Int32($0.count)) })
                    let owned = Array(nodes[0..<max(n, 0)])
                    for node in owned { byNode[node] = views.count }
                    // Modifiers often own no nodes of their own; they are listed all the same.
                    views.append(GraphView(nodes: owned, valueNode: LIAGTreeElementGetValue(element),
                                           type: unsafeBitCast(meta, to: Any.Type.self), typeName: known.name, parent: around, host: host))
                    names.append(known.name)
                    inner = views.count - 1
                }
            }
            guard depth < 400 else { return }
            let withSubgraphs = attachments.map { $0.contains(element) } ?? true
            let n = Int(children.withUnsafeMutableBufferPointer {
                LIAGTreeElementGetChildrenIncludingSubgraphs(element, $0.baseAddress!, Int32($0.count), withSubgraphs)
            })
            // Copied before recursing: the buffer is shared.
            for child in Array(children[0..<n]).reversed() {
                guard let child else { continue }
                collect(child, parent: index, around: inner, depth: depth + 1)
            }
        }
        collect(root, parent: -1, around: nil, depth: 0)
        // The views their bodies produced (elements of flags 0, whose value resolves to a body node), and the first box
        // recorded at or below each, as `_ViewDebug` gives the capture.
        var waitingBelow = [[Int]](repeating: [], count: elements.count)
        for (index, element) in elements.enumerated() {
            var waiting = parents[index] >= 0 ? waitingBelow[Int(parents[index])] : []
            if LIAGTreeElementGetFlags(element) == 0 {
                let source = LIAGGraphGetIndirectAttribute(LIAGTreeElementGetValue(element))
                if let view = byNode[source], !waiting.contains(view) { waiting.append(view) }
                if !waiting.isEmpty, let box = recordedBox(of: element) {
                    for view in waiting {
                        if views[view].frame == nil { views[view].frame = box }
                        views[view].bounds = views[view].bounds.map { $0.union(box) } ?? box
                    }
                    waiting = []
                }
            }
            waitingBelow[index] = waiting
        }
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
        // The forest can be older than the frame: a node that went away and was reused holds a value of another type.
        var rule: UnsafeRawPointer?, valueType: UnsafeRawPointer?
        if LIAGGraphGetAttributeTypes(view.valueNode, &rule, &valueType), valueType != meta { return nil }
        guard let pointer = LIAGGraphGetValue(view.valueNode, meta) else { return nil }
        func load<T>(_: T.Type) -> Any { pointer.assumingMemoryBound(to: T.self).pointee }
        return _openExistential(view.type, do: load)
    }
}

/// `LAYOUT_INSPECTOR_MATCH_DUMP` (a directory): writes what matching read for each capture, with the strings of every
/// view, as `match-NNN.json`, to replay the matching offline (``ComponentMatcher``). Holds the app's type names and
/// texts: anonymize it (`Tools/anonymize-match.py`) before it leaves the machine.
enum MatchRecorder {
    struct Recording: Codable {
        struct Host: Codable {
            var type: String
            var frame: [Double]
            var hidden: Bool
            var alpha: Double
            /// Its superviews up to the window: class, frame in the window, hidden, alpha, index among its siblings.
            var chain: [String]
        }

        var library: String
        var hosts: [Host]
        var input: MatchInput
    }

    private static var counter = 0

    static func writeIfRequested(_ capture: InspectorCapture, _ forest: ComponentGraph.Forest) {
        guard let dir = ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_MATCH_DUMP"], !dir.isEmpty else { return }
        counter += 1
        let hosts = forest.hosts.map { host in
            var hidden = false, alpha = 1.0
            var chain: [String] = []
            var next: UIView? = host
            while let view = next {
                hidden = hidden || view.isHidden
                alpha *= Double(view.alpha)
                let frame = view.convert(view.bounds, to: nil).values.map { Int($0) }
                let index = view.superview?.subviews.firstIndex { $0 === view }.map { "\($0)/\(view.superview!.subviews.count)" } ?? "-"
                chain.append("\(type(of: view)) \(frame) hidden \(view.isHidden) alpha \(view.alpha) clips \(view.clipsToBounds) at \(index)")
                next = view.superview
            }
            return Recording.Host(type: String(describing: type(of: host)), frame: host.convert(host.bounds, to: nil).values,
                                  hidden: hidden, alpha: alpha, chain: chain)
        }
        let recording = Recording(library: LayoutInspector.version, hosts: hosts, input: ComponentGraph.input(capture, forest, withStrings: true).0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(recording) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "match-%03d.json", counter)))
    }
}

#endif

