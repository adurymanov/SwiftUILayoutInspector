#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit
internal import LayoutInspectorAttributeGraph

/// How many times each component's `body` ran, by ``InspectorNode/id``.
struct RenderCounts: Equatable {
    struct Entry: Equatable {
        /// Body evaluations of this view, or of all `instances` views of its type together.
        var count: Int
        /// Views the count is shared by: 1 when the count is this view's own. More when AttributeGraph holds a different
        /// number of views of the type than the capture shows, so they cannot be told apart.
        var instances: Int
        /// The components that share one count have the same group (the views they share).
        var group = 0

        var perView: Double { Double(count) / Double(max(instances, 1)) }
        var label: String { instances > 1 ? "Σ\(count)/\(instances)" : "\(count)" }
    }

    var byNode: [Int: Entry] = [:]
    /// `false` when no view graph of the inspected screen could be found (iOS 18): nothing can be counted.
    var isGraphFound = true

    var hottest: (id: Int, entry: Entry)? {
        byNode.max { $0.value.perView < $1.value.perView }.map { ($0.key, $0.value) }
    }

    var maxPerView: Double { byNode.values.map(\.perView).max() ?? 0 }

    /// Components with a count, and how many of them have their own. The one tally the panel, the components list and
    /// `capture.json` show.
    struct Summary: Equatable {
        var views = 0
        var own = 0
        var shared: Int { views - own }
    }

    var summary: Summary {
        Summary(views: byNode.count, own: byNode.values.filter { $0.instances == 1 }.count)
    }

    /// Components that share one count, as the inspector shows them: by type, then by count.
    struct SharedGroup: Equatable {
        var title: String
        /// The total of the graph's views behind them.
        var count: Int
        /// Components on screen that share it.
        var components: Int
        /// Views of that type the graph holds there, on screen or not.
        var graphViews: Int

        var line: String {
            let on = components == 1 ? "1 view" : "\(components) views"
            return "\(title): Σ\(count) shared by \(on) (\(graphViews) in the graph)"
        }
    }

    /// `among`: only the groups with one of these components (the rows a list shows); all when `nil`.
    func sharedGroups(in capture: InspectorCapture, among: Set<Int>? = nil) -> [SharedGroup] {
        var groups: [Int: SharedGroup] = [:]
        let shown = among.map { among in Set(byNode.compactMap { among.contains($0.key) && $0.value.instances > 1 ? $0.value.group : nil }) }
        for (id, entry) in byNode where entry.instances > 1 && shown?.contains(entry.group) != false {
            guard let node = capture.node(withID: id) else { continue }
            groups[entry.group, default: SharedGroup(title: node.title, count: entry.count, components: 0, graphViews: entry.instances)].components += 1
        }
        return groups.values.sorted { ($0.count, $0.components, $1.title) > ($1.count, $1.components, $0.title) }
    }
}

/// Counts `body` evaluations with AttributeGraph's own profiler (`AGGraphStartProfiling`): every graph node records
/// how often it was updated while profiling is on. A component's `body` is a node (`StaticBody<ViewBodyAccessor<V>>`
/// or `DynamicBody<…>`, `…ModifierBodyAccessor<M>…` for a `ViewModifier`) owned by the component's tree element, so
/// the counts are exact and per view.
///
/// Profiling runs only between ``start(hosts:)`` and ``stop()``. Nothing here is touched otherwise.
final class RenderProfiler {
    /// `false` when a private symbol this needs is missing on this iOS version.
    static var isAvailable: Bool { AttributeGraphTree.isAvailable && LIAGProfilingIsAvailable() }

    /// Hosts whose graphs are read. Kept weakly: a graph context goes away with its screen, and AttributeGraph traps on
    /// a context that was invalidated.
    private var hosts: [WeakHost] = []
    private(set) var isRunning = false

    /// Starts profiling and resets the counts. Profiling is switched for every graph of the process at once: all view
    /// graphs of an app share one AttributeGraph graph, and a graph shown later (a sheet) is counted too.
    func start(hosts: [UIView]) {
        guard Self.isAvailable else { return }
        isRunning = true
        add(hosts: hosts)
        LIAGGraphStartProfiling(nil)
        LIAGGraphResetProfile(nil)
    }

    /// Hosts to read the counts through, besides the ones given to `start`.
    func add(hosts: [UIView]) {
        guard isRunning else { return }
        self.hosts.removeAll { $0.view == nil }
        for host in hosts where !self.hosts.contains(where: { $0.view === host }) { self.hosts.append(WeakHost(view: host)) }
    }

    /// At least one host of the inspected content has a graph (none on iOS 18, where the root subgraph isn't found).
    var hasGraphs: Bool { !liveGraphs().isEmpty }

    func reset() {
        guard isRunning else { return }
        LIAGGraphResetProfile(nil)
    }

    func stop() {
        guard isRunning else { return }
        LIAGGraphStopProfiling(nil)
        hosts = []
        isRunning = false
    }

    deinit { stop() }

    /// `AGGraphCounterQuery.graphID`.
    private static let graphIDCounter: UInt32 = 5

    /// One context per graph, from hosts that are still alive.
    private func liveGraphs() -> [UnsafeRawPointer] {
        Self.graphs(of: hosts.compactMap(\.view))
    }

    private static func graphs(of hosts: [UIView]) -> [UnsafeRawPointer] {
        var seen = Set<UInt64>()
        var result: [UnsafeRawPointer] = []
        for host in hosts {
            guard let subgraph = AttributeGraphTree.rootSubgraph(of: host), let graph = LIAGSubgraphGetGraph(subgraph) else { continue }
            if seen.insert(LIAGGraphGetCounter(graph, graphIDCounter)).inserted { result.append(graph) }
        }
        return result
    }

    private struct WeakHost {
        weak var view: UIView?
    }

    /// What the graphs of `hosts` have counted so far, read without starting, stopping or resetting anything.
    static func recordedBodyCounts(hosts: [UIView], nodes: Set<UInt32>) -> [UInt32: Int] {
        let graphs = graphs(of: hosts)
        var kinds: [UInt32: NodeKind] = [:]
        classify(nodes, in: graphs, into: &kinds)
        return bodyCounts(of: nodes, in: graphs, kinds: &kinds)
    }

    // MARK: - Reading
    //
    // AttributeGraph keeps an update count per node while profiling, and gives it out only through a description of
    // the graph. The full description (`graph/dict`) has every node of the app's graph: tens of thousands in a big app,
    // 0.3 s on the main thread. The `graph/dot` description takes `attribute-ids` and describes only those nodes, with
    // the count in each label ("…\n0.01%: 3 × 0.50μs"), in about a millisecond; but its label names the node's value
    // type, not its rule, so it can't tell a view's `body` from its other nodes. Nodes are therefore classified once,
    // from the full description, when they first come up (a new capture with new views), and read through the
    // short one every time after.

    private enum NodeKind: Equatable {
        /// A `body` node, with the label the short description first gave it.
        case body(label: String?)
        case other
        /// In no graph when it was classified; looked up again with the next capture.
        case absent
    }

    private var kinds: [UInt32: NodeKind] = [:]
    /// The view each classified node belonged to (its value node). AttributeGraph reuses the ids of nodes that went
    /// away: a node that turns up under another view is classified again, and so is one whose label changed.
    private var owners: [UInt32: UInt32] = [:]

    /// Classifies the nodes of a new capture that weren't classified for the same view before (one full description),
    /// so that reading them stays short. `owners`: node → the value node of the view that owns it.
    /// `known`: nodes already classified when they were read (``ComponentGraph/Forest/isBody``).
    func prepare(_ owners: [UInt32: UInt32], known: [UInt32: Bool] = [:]) {
        kinds = kinds.filter { node, kind in kind != .absent && owners[node] == self.owners[node] && owners[node] != nil }
        self.owners = owners
        var unknown = Set<UInt32>()
        for node in owners.keys where kinds[node] == nil {
            if let body = known[node] { kinds[node] = body ? .body(label: nil) : .other } else { unknown.insert(node) }
        }
        let graphs = liveGraphs()
        guard !unknown.isEmpty, !graphs.isEmpty else { return }
        Self.classify(unknown, in: graphs, into: &kinds)
    }

    /// Whether each rule type computes a view's `body`, by its metadata.
    private static var bodyRules: [UnsafeRawPointer: Bool] = [:]

    /// Whether a node computes a view's `body`, from the type of its rule (`AGGraphGetAttributeInfo`): a lookup per
    /// node, where the full description lists the whole graph. `nil` when AttributeGraph can't tell. Only for a node
    /// just read from a live tree.
    static func isBody(_ node: UInt32) -> Bool? {
        var rule: UnsafeRawPointer?, value: UnsafeRawPointer?
        guard LIAGGraphGetAttributeTypes(node, &rule, &value), let rule else { return nil }
        if let known = bodyRules[rule] { return known }
        // The name as the full description gives it (`AGTypeDescription`), so both ways test the same text.
        let type = unsafeBitCast(rule, to: Any.Type.self)
        let name = ViewDebugReader.readableName(of: type) ?? _typeName(type, qualified: false)
        let isBody = isBodyRule(name)
        bodyRules[rule] = isBody
        return isBody
    }

    static func isBodyRule(_ name: String) -> Bool {
        name.contains("Body<ViewBodyAccessor<") || name.contains("Body<ModifierBodyAccessor<")
    }

    func bodyCounts(of nodes: Set<UInt32>) -> [UInt32: Int] {
        Self.bodyCounts(of: nodes, in: liveGraphs(), kinds: &kinds)
    }

    private static func bodyCounts(of nodes: Set<UInt32>, in graphs: [UnsafeRawPointer], kinds: inout [UInt32: NodeKind]) -> [UInt32: Int] {
        let bodies = nodes.filter { if case .body = kinds[$0] { true } else { false } }
        guard !bodies.isEmpty else { return [:] }
        let ids = NSMutableIndexSet()
        for node in bodies { ids.add(Int(node)) }
        var result: [UInt32: Int] = [:]
        for graph in graphs {
            autoreleasepool {
                guard let labels = labels(of: ids, in: graph) else {
                    // No short description on this version: the full one, every time.
                    for (node, count) in classify(bodies, in: [graph], into: &kinds) where result[node] == nil { result[node] = count }
                    return
                }
                for (node, label) in labels where bodies.contains(node) && result[node] == nil {
                    let (name, count) = parse(label)
                    switch kinds[node] {
                    case .body(nil)?: kinds[node] = .body(label: name)
                    case .body(let known?)? where known != name:
                        // Reused by a node of another type: no count until the next capture classifies it again.
                        kinds[node] = .absent
                        continue
                    default: break
                    }
                    result[node] = count
                }
            }
        }
        return result
    }

    /// The labels of `ids` in the short description, by node. `nil` when this AttributeGraph has no such description.
    private static func labels(of ids: NSIndexSet, in graph: UnsafeRawPointer) -> [UInt32: Substring]? {
        let options = ["format": "graph/dot", "include-values": false, "attribute-ids": ids] as CFDictionary
        guard let text = LIAGGraphDescription(graph, options)?.takeUnretainedValue() as? String, text.hasPrefix("digraph") else { return nil }
        var result: [UInt32: Substring] = [:]
        // `  _22224[label="22224: VStack<…>\n0.0054%: 3 × 0.50μs"];`; edges (`_1 -> _2[]`) have no label.
        for line in text.split(separator: "\n") {
            guard let open = line.range(of: "[label=\""), line.first(where: { $0 != " " }) == "_" else { continue }
            let id = line[line.index(after: line.firstIndex(of: "_")!)..<open.lowerBound]
            guard let node = UInt32(id), let close = line.range(of: "\"", range: open.upperBound..<line.endIndex) else { continue }
            result[node] = line[open.upperBound..<close.lowerBound]
        }
        return result
    }

    /// The type part of a label and the update count after it (0 when the node never updated).
    private static func parse(_ label: Substring) -> (name: String, count: Int) {
        let parts = label.components(separatedBy: "\\n")
        var count = 0
        for part in parts.dropFirst() {
            guard let percent = part.range(of: "%: "), let times = part.range(of: " × ", range: percent.upperBound..<part.endIndex),
                  let value = Int(part[percent.upperBound..<times.lowerBound]) else { continue }
            count = value
            break
        }
        return (parts.first ?? "", count)
    }

    /// Marks each of `nodes` as a view's `body` or not, from the rule types of the full description.
    /// Reads it through `NSDictionary` / `NSArray`: bridging it to Swift collections copies the whole graph and costs
    /// several times more than AttributeGraph takes to describe it.
    @discardableResult
    private static func classify(_ nodes: Set<UInt32>, in graphs: [UnsafeRawPointer], into kinds: inout [UInt32: NodeKind]) -> [UInt32: Int] {
        var counts: [UInt32: Int] = [:]
        var seenGraphs = Set<Int>()
        for graph in graphs {
            autoreleasepool {
                let options = ["format": "graph/dict", "include-values": false] as CFDictionary
                // Not +1: forty descriptions grow the footprint by 256 KB, not by forty graphs.
                guard let description = LIAGGraphDescription(graph, options)?.takeUnretainedValue() as? NSDictionary,
                      let list = description.object(forKey: "graphs") as? NSArray else { return }
                for case let g as NSDictionary in list {
                    if let id = (g.object(forKey: "id") as? NSNumber)?.intValue {
                        if seenGraphs.contains(id) { continue }
                        seenGraphs.insert(id)
                    }
                    guard let types = g.object(forKey: "types") as? NSArray, let entries = g.object(forKey: "nodes") as? NSArray else { continue }
                    var isBody: [Int: Bool] = [:]
                    for case let entry as NSDictionary in entries {
                        guard let id = (entry.object(forKey: "id") as? NSNumber)?.uint32Value, nodes.contains(id),
                              let type = (entry.object(forKey: "type") as? NSNumber)?.intValue else { continue }
                        let body = isBody[type] ?? {
                            let name = type < types.count ? ((types[type] as? NSDictionary)?.object(forKey: "name") as? String) ?? "" : ""
                            let value = isBodyRule(name)
                            isBody[type] = value
                            return value
                        }()
                        if body {
                            if case .body = kinds[id] {} else { kinds[id] = .body(label: nil) }
                            let profile = entry.object(forKey: "profile") as? NSDictionary
                            counts[id] = (profile?.object(forKey: "update_count") as? NSNumber)?.intValue ?? 0
                        } else {
                            kinds[id] = .other
                        }
                    }
                }
            }
        }
        for node in nodes where kinds[node] == nil { kinds[node] = .absent }
        return counts
    }

    // MARK: - Views

    /// The graph nodes of every app view under `host`, by type, in the order SwiftUI declares the views.
    static func viewNodes(of host: UIView) -> [String: [[UInt32]]] {
        ComponentGraph.views(of: host).mapValues { $0.map(\.nodes) }
    }
}

/// Ties a capture's components to their body nodes (``ComponentGraph/match(_:)``, once per capture) and reads their
/// counts. Components that couldn't be told apart get the total of the views they share.
final class RenderHeatmap {
    let profiler = RenderProfiler()
    private weak var mappedCapture: InspectorCapture?
    private var slots: [(node: Int, nodes: [UInt32], instances: Int, group: Int)] = []
    private var wanted = Set<UInt32>()

    /// Timings of the last `map` and `read`, for the log.
    private(set) var lastMapDuration: TimeInterval = 0
    private(set) var lastReadDuration: TimeInterval = 0
    /// The parts of the last mapping: reading the graph's views, matching, classifying the nodes; and its longest step.
    private(set) var lastMapParts: (forest: TimeInterval, match: TimeInterval, classify: TimeInterval, longestStep: TimeInterval) = (0, 0, 0, 0)

    private var pending: (capture: InspectorCapture, forest: ComponentGraph.ForestBuilder?, matches: [Int: ComponentGraph.Match]?)?
    private var parts: (forest: TimeInterval, match: TimeInterval, classify: TimeInterval, longestStep: TimeInterval) = (0, 0, 0, 0)

    /// A mapping started by ``beginMap(_:)`` isn't done yet.
    var isMapping: Bool { pending != nil }

    /// Maps `capture` at once.
    func map(_ capture: InspectorCapture) {
        beginMap(capture)
        while !mapStep() {}
    }

    /// Starts mapping `capture` in steps (``mapStep()``), one per frame: each host's views, the matching, the
    /// classification. Until it is done, reads use the previous mapping.
    func beginMap(_ capture: InspectorCapture) {
        guard mappedCapture !== capture, pending?.capture !== capture else { return }
        let cached = ComponentGraph.cachedForest(of: capture) != nil
        pending = (capture, cached ? nil : ComponentGraph.ForestBuilder(capture), nil)
        parts = (0, 0, 0, 0)
    }

    /// One step of the mapping in progress. `true` when there is none left.
    @discardableResult
    func mapStep() -> Bool {
        guard let job = pending else { return true }
        let start = CACurrentMediaTime()
        defer {
            let spent = CACurrentMediaTime() - start
            parts.longestStep = max(parts.longestStep, spent)
        }
        if let forest = job.forest {
            let done = forest.step()
            parts.forest += CACurrentMediaTime() - start
            if done { pending?.forest = nil }
            return false
        }
        guard let matches = job.matches else {
            pending?.matches = ComponentGraph.match(job.capture)
            parts.match += CACurrentMediaTime() - start
            return false
        }
        mappedCapture = job.capture
        slots = matches.map { id, match in
            let nodes = match.views.flatMap(\.nodes)
            return (id, nodes, match.views.count, nodes.sorted().hashValue)
        }
        wanted = Set(slots.flatMap(\.nodes))
        var owners: [UInt32: UInt32] = [:]
        for match in matches.values { for view in match.views { for node in view.nodes { owners[node] = view.valueNode } } }
        profiler.prepare(owners, known: ComponentGraph.cachedForest(of: job.capture)?.isBody ?? [:])
        parts.classify += CACurrentMediaTime() - start
        parts.longestStep = max(parts.longestStep, CACurrentMediaTime() - start)
        lastMapParts = parts
        lastMapDuration = parts.forest + parts.match + parts.classify
        pending = nil
        return true
    }

    func read() -> RenderCounts {
        let start = CACurrentMediaTime()
        defer { lastReadDuration = CACurrentMediaTime() - start }
        guard profiler.isRunning, profiler.hasGraphs else { return RenderCounts(isGraphFound: false) }
        guard !wanted.isEmpty else { return RenderCounts() }
        let counts = profiler.bodyCounts(of: wanted)
        var result = RenderCounts()
        for slot in slots {
            let bodies = slot.nodes.compactMap { counts[$0] }
            guard !bodies.isEmpty else { continue }
            result.byNode[slot.node] = RenderCounts.Entry(count: bodies.reduce(0, +), instances: slot.instances, group: slot.group)
        }
        return result
    }

    /// Drops the mapping in progress (the screen changed under it); reads keep the previous one.
    func cancelMap() {
        pending = nil
    }

    /// Forget the mapping: the next `map` reads the views again.
    func invalidate() {
        mappedCapture = nil
        pending = nil
        slots = []
        wanted = []
    }
}

#endif
