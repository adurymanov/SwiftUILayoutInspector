#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// One capture of a view hierarchy: a SwiftUI tree per hosting view and the UIKit render tree.
///
/// Get one with ``LayoutInspector/capture(_:)`` or ``LayoutInspector/captureWhenStable(_:timeout:quietPeriod:until:)``.
/// Node frames are in the coordinate space of the captured view; after the view scrolls or moves call
/// ``resolveFrames(in:)`` again.
public final class InspectorCapture {
    /// One root (``NodeKind/host``) per SwiftUI hosting view: the screen, navigation destinations, list cells…
    public let swiftUIRoots: [InspectorNode]
    public let uikitRoot: InspectorNode
    /// `false` when SwiftUI does not record its debug graph (see ``LayoutInspector/bootstrap(isEnabled:)``):
    /// only the render tree is available then.
    public let isSwiftUIGraphAvailable: Bool
    /// How long the capture took.
    public let duration: TimeInterval
    public let date = Date()
    private(set) var issues: [LintIssue] = []
    /// What the presentations on screen hide (see `Occlusion`); `nil` when nothing opaque is presented.
    var occlusion: Occlusion?

    init(swiftUIRoots: [InspectorNode], uikitRoot: InspectorNode, isSwiftUIGraphAvailable: Bool, duration: TimeInterval) {
        self.swiftUIRoots = swiftUIRoots
        self.uikitRoot = uikitRoot
        self.isSwiftUIGraphAvailable = isSwiftUIGraphAvailable
        self.duration = duration
    }

    /// Every SwiftUI node, depth first.
    public var swiftUINodes: [InspectorNode] {
        var all: [InspectorNode] = []
        swiftUIRoots.forEach { $0.forEach { all.append($0) } }
        return all
    }

    /// Every UIKit view and render layer, depth first.
    public var uikitNodes: [InspectorNode] {
        var all: [InspectorNode] = []
        uikitRoot.forEach { all.append($0) }
        return all
    }

    /// Re-resolves every anchor into `space` (cheap – call on scroll / every frame). A SwiftUI node hidden by a
    /// presentation above its screen (a full-screen cover, an opaque sheet) gets a null frame, like one off screen.
    public func resolveFrames(in space: UIView) {
        func resolve(_ n: InspectorNode) {
            n.frame = n.anchor.resolve(in: space) ?? .null
            n.children.forEach(resolve)
        }
        guard let occlusion else {
            swiftUIRoots.forEach(resolve)
            resolve(uikitRoot)
            return
        }
        // A SwiftUI node is hidden when what its host shows of it is covered; a host covered whole hides its tree.
        func resolveBelow(_ n: InspectorNode, visible: CGRect, covers: [CGRect]) {
            let frame = n.anchor.resolve(in: space) ?? .null
            n.frame = frame.isNull || Occlusion.isHidden(frame, visible: visible, by: covers) ? .null : frame
            n.children.forEach { resolveBelow($0, visible: visible, covers: covers) }
        }
        for root in swiftUIRoots {
            guard let host = root.anchor.view, let hostFrame = root.anchor.resolve(in: space) else { resolve(root); continue }
            resolveBelow(root, visible: hostFrame.intersection(space.bounds), covers: occlusion.covers(of: host, in: space))
        }
        // UIKit views (labels, stack views of the screen below) by the presentation each one is in.
        var coversByView: [ObjectIdentifier: [CGRect]] = [:]
        func resolveUIKit(_ n: InspectorNode) {
            var frame = n.anchor.resolve(in: space) ?? .null
            if !frame.isNull, let view = n.anchor.view {
                let covers = coversByView[ObjectIdentifier(view)] ?? occlusion.covers(of: view, in: space)
                coversByView[ObjectIdentifier(view)] = covers
                if Occlusion.isHidden(frame, visible: space.bounds, by: covers) { frame = .null }
            }
            n.frame = frame
            n.children.forEach(resolveUIKit)
        }
        resolveUIKit(uikitRoot)
    }

    func runLint(rules: LayoutInspector.LintRules, bounds: CGRect) {
        issues = LayoutLint.run(on: self, rules: rules, bounds: bounds)
    }

    /// A visible `ProgressView` – the content is probably still loading.
    public var containsLoadingIndicator: Bool {
        swiftUINodes.contains { $0.kind == .control && $0.title == "ProgressView" && $0.isVisible }
    }

    public func node(withID id: Int) -> InspectorNode? {
        for root in swiftUIRoots { if let n = root.first(where: { $0.id == id }) { return n } }
        return uikitRoot.first { $0.id == id }
    }

    /// The first SwiftUI node whose title or text equals `query`, or whose detail contains it.
    ///
    /// ```swift
    /// capture.find("ProfileHeader", kind: .component)
    /// capture.find("Anna Petrova", kind: .text)?.font?.size
    /// ```
    public func find(_ query: String, kind: NodeKind? = nil) -> InspectorNode? {
        for root in swiftUIRoots {
            if let hit = root.find(query, kind: kind) { return hit }
        }
        return nil
    }

    /// SwiftUI nodes of `kind` (all of them when `nil`), depth first.
    public func nodes(_ kind: NodeKind? = nil) -> [InspectorNode] {
        swiftUINodes.filter { kind == nil || $0.kind == kind }
    }

    /// Checks the captured layout against design rules – what ``LayoutInspector/Mode/lint`` shows.
    /// - Parameter bounds: only nodes intersecting this rect (in the space of the last ``resolveFrames(in:)``).
    public func lintIssues(rules: LayoutInspector.LintRules = LayoutInspector.LintRules(), in bounds: CGRect = .infinite) -> [LintIssue] {
        LayoutLint.run(on: self, rules: rules, bounds: bounds)
    }

    /// Text "layout snapshot" (see ``LayoutReport``).
    public func report(_ options: LayoutReport.Options = LayoutReport.Options()) -> String {
        LayoutReport.text(for: self, options: options)
    }
}

enum LayoutCapture {
    /// Use AttributeGraph tree elements to restore app-defined components (see `ComponentReconstruction`).
    static var reconstructComponents = true
    static var lastReconstructionLog: [String] { ComponentReconstruction.log }

    /// Captures everything visible inside `root` (a window or any view). `excluding` – inspector's own views.
    static func capture(_ root: UIView, excluding: [UIView] = []) -> InspectorCapture {
        let job = Job(root: root, excluding: excluding)
        while !job.step() {}
        return job.result!
    }

    /// A capture split into steps, so a caller can spread it over frames and show progress in between.
    /// A step is one hosting view's AttributeGraph tree, reading its `_ViewDebug` data, encoding the values it needs
    /// (split further, see `step(budget:)`), building its tree, or the UIKit tree.
    final class Job {
        private let steps: [Step]
        private let output: Output
        private let totalWeight: Double
        private var doneWeight: Double = 0
        private var next = 0

        init(root: UIView, excluding: [UIView]) {
            let output = Output()
            self.output = output
            steps = LayoutCapture.steps(root: root, excluding: excluding, output: output)
            totalWeight = steps.reduce(0) { $0 + $1.weight }
        }

        /// 0…1, by the expected cost of the steps done.
        var progress: Double {
            guard totalWeight > 0 else { return 1 }
            let current = next < steps.count ? steps[next].weight * (steps[next].fraction?() ?? 0) : 0
            return min(1, (doneWeight + current) / totalWeight)
        }

        /// Set when the last step has run.
        var result: InspectorCapture? { output.capture }

        /// Runs the next step to its end. `true` once the capture is ready.
        func step() -> Bool {
            guard next < steps.count else { return true }
            while !steps[next].run(.infinity) {}
            doneWeight += steps[next].weight
            next += 1
            return next == steps.count
        }

        /// Runs steps until `budget` seconds have passed, `true` once the capture is ready. A step that can be
        /// split stops at the budget and goes on in the next call; one that cannot runs to its end.
        func step(budget: TimeInterval) -> Bool {
            let deadline = CACurrentMediaTime() + budget
            while next < steps.count {
                guard steps[next].run(deadline) else { return false }
                doneWeight += steps[next].weight
                next += 1
                if next < steps.count, CACurrentMediaTime() >= deadline { return false }
            }
            return true
        }
    }

    private struct Step {
        let weight: Double
        /// Runs (part of) the step, stopping at the deadline if it can. `true` when the step is complete.
        let run: (_ deadline: CFTimeInterval) -> Bool
        var fraction: (() -> Double)?
    }

    /// The `_ViewDebug` trees of one hosting view between the steps that read, encode and build them.
    private final class HostTrees {
        var roots: [RawDebugNode]?
        var pending: [RawDebugNode] = []
        var prepared = 0
    }

    private final class Output {
        var capture: InspectorCapture?
    }

    private static func steps(root: UIView, excluding: [UIView], output: Output) -> [Step] {
        let nextID: () -> Int = { idCounter += 1; return idCounter }
        var timings: [String: Double] = [:]
        var busy: Double = 0
        var longest: Double = 0
        func measure<T>(_ key: String, _ body: () -> T) -> T {
            let t = CACurrentMediaTime()
            defer { timings[key, default: 0] += CACurrentMediaTime() - t }
            return body()
        }
        var steps: [Step] = []
        func add(_ weight: Double, fraction: (() -> Double)? = nil, splittable body: @escaping (CFTimeInterval) -> Bool) {
            steps.append(Step(weight: weight, run: { deadline in
                let t = CACurrentMediaTime()
                let done = body(deadline)
                busy += CACurrentMediaTime() - t
                longest = max(longest, CACurrentMediaTime() - t)
                return done
            }, fraction: fraction))
        }
        func add(_ weight: Double, _ body: @escaping () -> Void) {
            add(weight) { _ in body(); return true }
        }

        let setupStart = CACurrentMediaTime()
        ComponentReconstruction.log = []
        ComponentReconstruction.applySpent = [:]
        ViewDebugReader.encodingTimes = [:]
        let allHosts = visibleHostingViews(in: root, excluding: excluding)
        // Hosts fully covered by a nested host (the app root around a NavigationStack) draw nothing themselves:
        // skip their (huge) `_ViewDebug` data, but keep their AttributeGraph tree – app screens are declared there.
        let hosts = skipCoveredHosts ? allHosts.filter { !isCovered($0, by: allHosts) } : allHosts

        // Per-host cache: a host whose render tree did not change keeps its previous trees.
        // (The first capture of new content is expensive – Swift runtime warms up metadata for every new
        // SwiftUI type in the debug values – subsequent captures of the same content take a few ms.)
        var fresh: [UIView] = []
        var signatures: [ObjectIdentifier: Int] = [:]
        for host in hosts {
            let signature = layoutSignature(of: host)
            signatures[ObjectIdentifier(host)] = signature
            if useCache, let cached = cache[ObjectIdentifier(host)], cached.signature == signature, cached.host === host { continue }
            fresh.append(host)
        }
        busy += CACurrentMediaTime() - setupStart

        // App-defined views are missing from `_ViewDebug` data – recover them from AttributeGraph.
        var agTrees: [AttributeGraphTree.Element] = []
        var freshAG: [ObjectIdentifier: AttributeGraphTree.Element] = [:]
        if reconstructComponents {
            for host in allHosts {
                let id = ObjectIdentifier(host)
                let signature = signatures[id] ?? layoutSignature(of: host)
                let cachedAG = useCache ? agCache[id].flatMap { $0.signature == signature && $0.host === host ? $0.tree : nil } : nil
                add(cachedAG == nil ? 1 : 0.05) {
                    if let cachedAG {
                        agTrees.append(cachedAG)
                    } else if !fresh.contains(where: { $0 === host }), let tree = cache[id]?.attributeGraph {
                        agTrees.append(tree)
                    } else if let tree = measure("attributeGraph[\(TypeNames.shortClassName(host))]", { AttributeGraphTree.tree(of: host) }) {
                        agTrees.append(tree)
                        freshAG[id] = tree
                        agCache[id] = AGCacheEntry(host: host, signature: signature, tree: tree)
                    }
                }
            }
        }
        var reconstruction: ComponentReconstruction?
        add(0.2) {
            // Only hosts read again need it, and the same AttributeGraph trees give the same index.
            guard !fresh.isEmpty else { return }
            if let last = lastReconstruction, last.trees.count == agTrees.count,
               zip(last.trees, agTrees).allSatisfy({ $0 === $1 }) {
                reconstruction = last.index
            } else {
                let index = measure("reconstructIndex") { ComponentReconstruction(trees: agTrees) }
                lastReconstruction = (agTrees, index)
                reconstruction = index
            }
        }

        var roots: [InspectorNode] = []
        var graphAvailable = false
        var newCache: [ObjectIdentifier: CacheEntry] = [:]
        for host in hosts {
            let id = ObjectIdentifier(host)
            guard fresh.contains(where: { $0 === host }) else {
                add(0.05) {
                    guard let cached = cache[id] else { return }
                    newCache[id] = cached
                    graphAvailable = true
                    if let tree = cached.tree { roots.append(tree) }
                }
                continue
            }
            let trees = HostTrees()
            // A host that left its window between the steps (a screen popped meanwhile) is no longer on screen. A
            // host without a window from the start (`capture(_:)` of a detached view) is still read.
            weak var window = host.window
            let hadWindow = window != nil
            let isOnScreen = { !hadWindow || (window != nil && host.window === window) }
            let hostKey = "viewDebugData[\(TypeNames.shortClassName(host))]"
            // Read: cheap, the data is SwiftUI's own record of the graph.
            add(0.3) {
                guard isOnScreen() else { return }
                let ran = SwiftUIGraphReader.inUpdate(of: host) { readDebugData in
                    let data = measure(hostKey) { readDebugData() }
                    guard let raw = measure("rawTree", { ViewDebugReader.trees(data, host: host) }) else { return }
                    raw.forEach(SwiftUIGraphReader.pruneHidden)
                    trees.roots = raw
                    trees.pending = measure("rawTree") { SwiftUITreeBuilder.nodesReadingValues(in: raw) }
                }
                if !ran, host is ViewDebugDataProviding {
                    ComponentReconstruction.log.append("\(TypeNames.shortClassName(host)): SwiftUI did not run the update, SwiftUI tree skipped")
                }
            }
            // Encode the values the tree is built from: the expensive part (SwiftUI reflects them), split by node.
            add(3, fraction: { trees.pending.isEmpty ? 1 : Double(trees.prepared) / Double(trees.pending.count) }) { deadline in
                guard trees.roots != nil, isOnScreen(), trees.prepared < trees.pending.count else { return true }
                let ran = SwiftUIGraphReader.inUpdate(of: host) { _ in
                    measure("values") {
                        repeat {
                            SwiftUITreeBuilder.prepareValues(of: trees.pending[trees.prepared])
                            trees.prepared += 1
                        } while trees.prepared < trees.pending.count && CACurrentMediaTime() < deadline
                    }
                }
                // No update, no progress: leave the values to the build, which encodes what it reads.
                return !ran || trees.prepared >= trees.pending.count
            }
            add(0.7) {
                guard let rawRoots = trees.roots, isOnScreen() else { return }
                func build() {
                    if let reconstruction { measure("reconstructApply") { reconstruction.apply(to: rawRoots) } }
                    if !rawRoots.isEmpty { graphAvailable = true }
                    let tree = measure("semanticTree") { SwiftUITreeBuilder(host: host, nextID: nextID).build(roots: rawRoots) }
                    let kept = tree.children.isEmpty ? nil : tree
                    if let kept { roots.append(kept) }
                    newCache[id] = CacheEntry(host: host, signature: signatures[id] ?? 0, tree: kept, attributeGraph: freshAG[id])
                }
                // The data is already read: without an update the tree is still built, from the copied values.
                if !SwiftUIGraphReader.inUpdate(of: host, { _ in build() }) { build() }
            }
        }

        add(1) {
            cache = newCache
            let finalStart = CACurrentMediaTime()
            let uikit = measure("uikit") { UIKitCapture.capture(root: root, excluding: excluding, nextID: nextID) }
            // Time spent capturing, without the frames between steps.
            let duration = busy + CACurrentMediaTime() - finalStart
            let capture = InspectorCapture(swiftUIRoots: roots, uikitRoot: uikit, isSwiftUIGraphAvailable: graphAvailable,
                                           duration: duration)
            capture.occlusion = Occlusion(root: root)
            output.capture = capture
            lastTimings = ["total \(Int(duration * 1000)) ms"]
                + timings.sorted { $0.value > $1.value }.map { "\($0.key) \(Int($0.value * 1000)) ms" }
                + ViewDebugReader.encodingSummary
                + (timings["reconstructIndex"] == nil ? [] : ComponentReconstruction.phases.map { "index.\($0.0) \(Int($0.1 * 1000)) ms" })
                + (timings["reconstructApply"] == nil ? [] : ComponentReconstruction.applySpent.sorted { $0.value > $1.value }.map { "apply.\($0.0) \(Int($0.1 * 1000)) ms" })
                + ["hosts \(hosts.count), re-captured \(fresh.count)",
                   "longest step \(Int(max(longest, CACurrentMediaTime() - finalStart) * 1000)) ms"]
        }
        return steps
    }

    private struct CacheEntry {
        weak var host: UIView?
        var signature: Int
        var tree: InspectorNode?
        var attributeGraph: AttributeGraphTree.Element?
    }

    private struct AGCacheEntry {
        weak var host: UIView?
        var signature: Int
        var tree: AttributeGraphTree.Element
    }

    private static var cache: [ObjectIdentifier: CacheEntry] = [:]
    private static var agCache: [ObjectIdentifier: AGCacheEntry] = [:]
    private static var idCounter = 0
    /// Kept with its trees, which also keeps them alive for the identity check.
    private static var lastReconstruction: (trees: [AttributeGraphTree.Element], index: ComponentReconstruction)?
    static var lastReconstructionIndex: ComponentReconstruction? { lastReconstruction?.index }

    /// Reuse trees of hosting views whose render tree did not change since the previous capture.
    static var useCache = true

    static func resetCache() {
        cache = [:]; agCache = [:]; lastReconstruction = nil
        ComponentReconstruction.resetTypeCache()
    }

    /// Where the time of the last capture went (diagnostics).
    private(set) static var lastTimings: [String] = []

    /// Skip hosting views whose whole area is covered by a nested hosting view (e.g. the app root host that only
    /// contains a `NavigationStack`): their debug graph is huge (everything ever pushed) and draws nothing visible.
    static var skipCoveredHosts = true

    static func visibleHostingViews(in root: UIView, excluding: [UIView]) -> [UIView] {
        var result: [UIView] = []
        func walk(_ v: UIView) {
            if excluding.contains(where: { $0 === v }) || v.isHidden || v.alpha < 0.01 { return }
            if SwiftUIGraphReader.isHostingView(v) { result.append(v) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return result
    }

    static func isCovered(_ host: UIView, by hosts: [UIView]) -> Bool {
        let frame = host.convert(host.bounds, to: nil)
        return hosts.contains { other in
            other !== host && other.isDescendant(of: host)
                && other.convert(other.bounds, to: nil).insetBy(dx: -1, dy: -1).contains(frame)
        }
    }

    /// Cheap fingerprint of the render tree: changes when something is added/moved/resized,
    /// but not when a scroll view scrolls (bounds.origin is ignored). Used to auto-refresh on dynamic data.
    static func layoutSignature(of root: UIView, excluding: [UIView] = []) -> Int {
        var hasher = Hasher()
        var count = 0
        func walk(_ layer: CALayer, depth: Int) {
            guard depth < 64 else { return }
            count += 1
            hasher.combine(ObjectIdentifier(layer))
            if !(layer.delegate is UIScrollView) {
                hasher.combine(layer.position.x); hasher.combine(layer.position.y)
            }
            hasher.combine(layer.bounds.size.width); hasher.combine(layer.bounds.size.height)
            hasher.combine(layer.isHidden)
            // Inside a text field or view only its frame counts: the caret blinks, and TextKit 2 replaces the views
            // that draw the text whenever the field is read – which the capture does, so it would re-capture forever.
            if layer.delegate is UITextInput { return }
            if let contents = layer.contents { hasher.combine(ObjectIdentifier(contents as AnyObject)) }
            for sub in layer.sublayers ?? [] {
                if let v = sub.delegate as? UIView, excluding.contains(where: { $0 === v }) { continue }
                walk(sub, depth: depth + 1)
            }
        }
        walk(root.layer, depth: 0)
        hasher.combine(count)
        return hasher.finalize()
    }

    /// Fingerprint of scroll positions – when it changes the overlay only needs to be re-resolved, not re-captured.
    static func scrollSignature(of root: UIView) -> Int {
        var hasher = Hasher()
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView { hasher.combine(s.contentOffset.x); hasher.combine(s.contentOffset.y) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return hasher.finalize()
    }
}

#endif
