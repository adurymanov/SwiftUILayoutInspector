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
}

/// Counts `body` evaluations with AttributeGraph's own profiler (`AGGraphStartProfiling`): every graph node records
/// how often it was updated while profiling is on. A component's `body` is a node (`StaticBody<ViewBodyAccessor<V>>`
/// or `DynamicBody<…>`) owned by the component's tree element, so the counts are exact and per view.
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
        bodyCounts(of: nodes, in: graphs(of: hosts))
    }

    // MARK: - Reading

    func bodyCounts(of nodes: Set<UInt32>) -> [UInt32: Int] {
        Self.bodyCounts(of: nodes, in: liveGraphs())
    }

    /// Update counts of the body nodes among `nodes`, by node. Nodes that aren't a view's body are left out.
    /// Reads the description through `NSDictionary` / `NSArray`: bridging it to Swift collections copies the whole graph
    /// and costs several times more than AttributeGraph takes to describe it.
    private static func bodyCounts(of nodes: Set<UInt32>, in graphs: [UnsafeRawPointer]) -> [UInt32: Int] {
        var result: [UInt32: Int] = [:]
        var seenGraphs = Set<Int>()
        for graph in graphs {
            autoreleasepool {
                guard let description = describe(graph),
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
                            let value = name.contains("Body<ViewBodyAccessor<")
                            isBody[type] = value
                            return value
                        }()
                        guard body else { continue }
                        let profile = entry.object(forKey: "profile") as? NSDictionary
                        result[id] = (profile?.object(forKey: "update_count") as? NSNumber)?.intValue ?? 0
                    }
                }
            }
        }
        return result
    }

    private static func describe(_ graph: UnsafeRawPointer) -> NSDictionary? {
        let options = ["format": "graph/dict", "include-values": false] as CFDictionary
        // Not +1: forty descriptions grow the footprint by 256 KB, not by forty graphs.
        return LIAGGraphDescription(graph, options)?.takeUnretainedValue() as? NSDictionary
    }

    // MARK: - Views

    /// The graph nodes of every app view under `host`, by type, in the order SwiftUI declares the views.
    static func viewNodes(of host: UIView) -> [String: [[UInt32]]] {
        ComponentGraph.views(of: host).mapValues { $0.map(\.nodes) }
    }
}

/// Ties a capture's components to their body nodes and reads their counts.
///
/// A capture builds its nodes in the order of SwiftUI's tree (``InspectorNode/id`` grows with it, before the children
/// are sorted by position), and AttributeGraph walks the same tree: the k-th `Row` of a host in one is the k-th `Row` in
/// the other. When the numbers differ (a view the capture could not place), the views of that type share their total.
final class RenderHeatmap {
    let profiler = RenderProfiler()
    private weak var mappedCapture: InspectorCapture?
    private var slots: [(node: Int, nodes: [UInt32], instances: Int)] = []
    private var wanted = Set<UInt32>()

    /// Timings of the last `map` and `read`, for the log.
    private(set) var lastMapDuration: TimeInterval = 0
    private(set) var lastReadDuration: TimeInterval = 0

    func map(_ capture: InspectorCapture) {
        guard mappedCapture !== capture else { return }
        let start = CACurrentMediaTime()
        mappedCapture = capture
        slots = ComponentGraph.match(capture).map { id, match in (id, match.views.flatMap(\.nodes), match.views.count) }
        wanted = Set(slots.flatMap(\.nodes))
        lastMapDuration = CACurrentMediaTime() - start
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
            result.byNode[slot.node] = RenderCounts.Entry(count: bodies.reduce(0, +), instances: slot.instances)
        }
        return result
    }

    /// Forget the mapping: the next `map` reads the views again.
    func invalidate() {
        mappedCapture = nil
        slots = []
        wanted = []
    }
}

#endif
