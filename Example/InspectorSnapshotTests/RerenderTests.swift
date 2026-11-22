import SwiftUI
import XCTest
@_spi(Diagnostics) @testable import LayoutInspector
@testable import InspectorDemo

/// Re-renders mode: exact body counts per view, Reset, and no profiling outside the mode.
@MainActor
final class RerenderTests: XCTestCase {
    override func tearDown() async throws {
        LayoutInspector.hide()
        try await super.tearDown()
    }

    /// Changing one `@Observable` property re-renders its reader only, and each row of a list is counted on its own.
    func test_observableProperty_rerendersOnlyItsReader() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        let model = RerenderModel()
        let harness = ScreenHarness(RerenderScreen(model: model))
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        let heatmap = RenderHeatmap()
        heatmap.profiler.start(hosts: Self.hosts(in: harness.window))
        defer { heatmap.profiler.stop() }
        try Self.skipWithoutGraph(heatmap)
        heatmap.map(capture)

        for _ in 0..<5 { model.balance += 1; harness.window.layoutIfNeeded() }
        for _ in 0..<2 { model.quotes[1].price += 1; harness.window.layoutIfNeeded() }

        let counts = heatmap.read()
        XCTAssertEqual(Self.count(of: "WalletBalance", in: capture, counts), [5])
        XCTAssertEqual(Self.count(of: "InboxBadge", in: capture, counts), [0])
        XCTAssertEqual(Self.count(of: "QuoteRow", in: capture, counts), [0, 2, 0], "rows top to bottom")
    }

    func test_reset_countsFromZero() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        let model = RerenderModel()
        let harness = ScreenHarness(RerenderScreen(model: model))
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        let heatmap = RenderHeatmap()
        heatmap.profiler.start(hosts: Self.hosts(in: harness.window))
        defer { heatmap.profiler.stop() }
        try Self.skipWithoutGraph(heatmap)
        heatmap.map(capture)

        for _ in 0..<4 { model.notifications += 1; harness.window.layoutIfNeeded() }
        XCTAssertEqual(Self.count(of: "InboxBadge", in: capture, heatmap.read()), [4])

        heatmap.profiler.reset()
        XCTAssertEqual(Self.count(of: "InboxBadge", in: capture, heatmap.read()), [0])
        model.notifications += 1
        harness.window.layoutIfNeeded()
        XCTAssertEqual(Self.count(of: "InboxBadge", in: capture, heatmap.read()), [1])
    }

    /// The inspector profiles only while it highlights in Re-renders; switching to another mode stops AttributeGraph's
    /// profiler, so the graph records nothing more.
    func test_otherMode_stopsProfiling() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        let model = RerenderModel()
        let harness = ScreenHarness(RerenderScreen(model: model).layoutInspector(.rerenders))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeCapture != nil && InspectorPresenter.shared.frontmost?.renderCounts != nil }
        if InspectorPresenter.shared.frontmost?.renderCounts?.isGraphFound == false {
            throw XCTSkip("no view graph on this iOS version: the mode shows it is unavailable")
        }
        try await waitUntil { LayoutInspector.activeCapture?.find("WalletBalance", kind: .component) != nil }
        let session = try XCTUnwrap(InspectorPresenter.shared.frontmost)
        XCTAssertTrue(session.isProfiling)

        for _ in 0..<3 { model.balance += 1; harness.window.layoutIfNeeded() }
        session.resetRenderCounts()
        for _ in 0..<3 { model.balance += 1; harness.window.layoutIfNeeded() }
        try await waitUntil {
            guard let capture = session.capture, let counts = session.renderCounts else { return false }
            return Self.count(of: "WalletBalance", in: capture, counts) == [3]
        }
        XCTAssertTrue(session.reportText?.contains("renders 3") == true, session.reportText ?? "no report")

        session.configuration.mode = .components
        XCTAssertFalse(session.isProfiling)
        XCTAssertNil(session.renderCounts)
        let hosts = Self.hosts(in: harness.window)
        let bodies = Set(hosts.flatMap { RenderProfiler.viewNodes(of: $0)["InspectorDemo.WalletBalance"] ?? [] }.flatMap { $0 })
        let before = RenderProfiler.recordedBodyCounts(hosts: hosts, nodes: bodies)
        for _ in 0..<5 { model.balance += 1; harness.window.layoutIfNeeded() }
        XCTAssertEqual(RenderProfiler.recordedBodyCounts(hosts: hosts, nodes: bodies), before)
        XCTAssertEqual(before.values.reduce(0, +), 3)
    }

    /// One text component all over a lazy list: the graph holds more of them than the capture shows (rows off screen,
    /// a hidden copy), and each one on screen still gets its own count.
    func test_lazyList_countsEachLabel() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        let model = LedgerModel()
        let harness = ScreenHarness(LabelsScreen(model: model))
        defer { harness.tearDown() }
        try await harness.waitUntilLoaded()
        // Scrolled down and back: the lazy stack keeps the rows it built below the screen.
        let scroll = try XCTUnwrap(Self.scrollView(in: harness.window))
        for y in [800.0, 1600, 0] {
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            harness.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
        }
        let capture = try await harness.waitUntilLoaded()
        capture.resolveFrames(in: harness.window)
        let heatmap = RenderHeatmap()
        heatmap.profiler.start(hosts: Self.hosts(in: harness.window))
        defer { heatmap.profiler.stop() }
        try Self.skipWithoutGraph(heatmap)
        heatmap.map(capture)

        let labels = capture.swiftUINodes.filter { $0.title == "BrandLabel" }
        let inGraph = Self.hosts(in: harness.window).flatMap { ComponentGraph.views(of: $0)["InspectorDemo.BrandLabel"] ?? [] }
        XCTAssertGreaterThan(inGraph.count, labels.count, "the graph should hold labels the capture doesn't show")

        for _ in 0..<3 { model.lines[2].amount += 1; harness.window.layoutIfNeeded() }
        let counts = heatmap.read()
        // Every label on screen is told apart, the identical "Card payment" ones and the formatted amounts included.
        // Only the header and its hidden copy, drawn in the same place, share one count.
        let shared = labels.filter { counts.byNode[$0.id]?.instances != 1 }
        XCTAssertEqual(Set(shared.map { ComponentGraph.texts(in: $0).first ?? "" }), Set(shared.isEmpty ? [] : ["Ledger"]), "labels sharing a count")
        let changed = labels.filter { counts.byNode[$0.id]?.count == 3 }
        XCTAssertEqual(changed.count, 1)
        let rows = capture.swiftUINodes.filter { $0.title == "LedgerRow" && $0.isVisible }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertGreaterThan(rows.count, 2)
        XCTAssertTrue(rows.count > 2 && changed.first.map { label in label.path.contains { $0 === rows[2] } } == true,
                      "the count is on another label")
        XCTAssertEqual(labels.compactMap { counts.byNode[$0.id]?.count }.reduce(0, +), 3)
    }

    /// A trading app's home: prices in generic streaming wrappers around a TimelineView, the same "0.00%" everywhere,
    /// cards that are geometry groups (SwiftUI records the same box inside every card), overlays that draw nothing,
    /// and tab items in hosting controllers of their own, two at each place. Each one is still counted on its own, and
    /// a change in one price lands on that price's views only.
    func test_streamingWrappers_countEachView() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        let model = MarketsModel()
        let harness = ScreenHarness(MarketsScreen(model: model, showsShimmer: false))
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        let heatmap = RenderHeatmap()
        heatmap.profiler.start(hosts: Self.hosts(in: harness.window))
        defer { heatmap.profiler.stop() }
        try Self.skipWithoutGraph(heatmap)
        heatmap.map(capture)

        let quote = try XCTUnwrap(model.quotes["NVDA"])
        for _ in 0..<3 { quote.percent += 1; harness.window.layoutIfNeeded() }
        let counts = heatmap.read()
        let summary = counts.summary
        XCTAssertGreaterThan(summary.views, 80)
        XCTAssertLessThan(Double(summary.shared) / Double(summary.views), 0.05, "views sharing a count: \(counts.sharedGroups(in: capture))")
        for title in ["TabItemLabel", "InstrumentCard", "InstrumentRow", "PriceDelta", "StreamValue"] {
            let nodes = capture.swiftUINodes.filter { $0.kind == .component && $0.title == title }
            XCTAssertFalse(nodes.isEmpty, title)
            XCTAssertEqual(nodes.filter { (counts.byNode[$0.id]?.instances ?? 1) > 1 }.count, 0, "\(title) sharing a count")
            // A view the inspector can't place for sure gets no count at all, rarely.
            XCTAssertLessThanOrEqual(nodes.filter { counts.byNode[$0.id] == nil }.count, max(2, nodes.count / 10), "\(title) without a count")
        }
        // The price of NVDA, in its card and in its row; every other price stays at zero.
        func owner(_ node: InspectorNode) -> String? {
            node.path.last { $0.title == "InstrumentCard" || $0.title == "InstrumentRow" }.map { ComponentGraph.texts(in: $0).contains("NVDA") ? "NVDA" : "other" }
        }
        let deltas = capture.swiftUINodes.filter { $0.kind == .component && $0.title == "PriceDelta" && owner($0) != nil }
        // (The capture doesn't show every PriceDelta of the rows: the ones it shows are checked.)
        let nvda = deltas.filter { owner($0) == "NVDA" }.map { counts.byNode[$0.id]?.count }
        XCTAssertFalse(nvda.isEmpty)
        XCTAssertEqual(Set(nvda), [3])
        XCTAssertEqual(Set(deltas.filter { owner($0) == "other" }.map { counts.byNode[$0.id]?.count }), [0])
    }

    /// An `Animatable` modifier with a repeating animation runs its `body` on every frame; the view it is applied to
    /// doesn't. The count is the modifier's, shown on that view's row in the components list.
    func test_animatableModifier_countsEveryFrame() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        // Started after the capture: a capture waits for the screen to settle, and a shimmer never does.
        let shimmerSwitch = ShimmerSwitch(isOn: false)
        let harness = ScreenHarness(VStack { NewProductsButton(shimmer: shimmerSwitch); Spacer() }.padding(.top, 80))
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        try XCTSkipIf(capture.nodes(.component).isEmpty, "no component names on this iOS version (iOS 18)")
        let heatmap = RenderHeatmap()
        heatmap.profiler.start(hosts: Self.hosts(in: harness.window))
        defer { heatmap.profiler.stop() }
        try Self.skipWithoutGraph(heatmap)
        heatmap.map(capture)
        shimmerSwitch.isOn = true
        try await Task.sleep(for: .seconds(1))
        let counts = heatmap.read()
        let shimmer = try XCTUnwrap(capture.swiftUINodes.first { $0.title == "Shimmer" })
        let button = try XCTUnwrap(capture.swiftUINodes.first { $0.title == "NewProductsButton" })
        XCTAssertGreaterThan(counts.byNode[shimmer.id]?.count ?? 0, 10, "a body per animation frame")
        XCTAssertEqual(counts.byNode[shimmer.id]?.instances, 1)
        // The button's own body ran only when the switch started the animation.
        XCTAssertLessThanOrEqual(counts.byNode[button.id]?.count ?? 99, 2)
        let list = ComponentList(capture, modifierTypes: ComponentGraph.modifierTypes(in: capture))
        let row = try XCTUnwrap(list.folded.first { $0.node === button || $0.wrappers.contains { $0 === button } })
        XCTAssertEqual(ComponentList.wrapperRenders(of: row, counts: counts).map(\.title), ["Shimmer"])
    }

    /// Views that share a count are not labelled one by one: the total shows once, in the panel.
    func test_sharedCount_isShownOnce() async throws {
        let harness = ScreenHarness(RerenderScreen())
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        try XCTSkipIf(capture.nodes(.component).isEmpty, "no component names on this iOS version (iOS 18)")
        let rows = capture.swiftUINodes.filter { $0.title == "QuoteRow" }
        let balance = try XCTUnwrap(capture.swiftUINodes.first { $0.title == "WalletBalance" })
        var counts = RenderCounts()
        for row in rows { counts.byNode[row.id] = .init(count: 6, instances: rows.count) }
        counts.byNode[balance.id] = .init(count: 5, instances: 1)

        var options = InspectorRenderOptions(mode: .rerenders)
        options.renderCounts = counts
        let card = InspectorCard()
        options.card = card
        _ = InspectorImageRenderer.image(of: harness.window, capture: capture, options: options)
        let lines = try XCTUnwrap(card.content?.lines)
        XCTAssertEqual(lines.first, "hottest: WalletBalance 5")
        XCTAssertEqual(lines.filter { $0.contains("QuoteRow") }, ["QuoteRow: Σ6 shared by 3 views (3 in the graph)"])
        XCTAssertTrue(lines.contains("3 of 4 views share a count with views they can't be told from:"), "\(lines)")
        // Above the components list: only for the rows it shows.
        let listed = ComponentList(capture).rows(ComponentList.Filter(), ComponentList.Context(bounds: harness.window.bounds))
        XCTAssertEqual(ComponentListView.sharedCounts(counts, capture: capture, rows: listed), ["QuoteRow: Σ6 shared by 3 views (3 in the graph)"])
        XCTAssertEqual(ComponentListView.sharedCounts(counts, capture: capture, rows: listed.filter { $0.node.title != "QuoteRow" }), [])
    }

    /// A sheet counted while it is on screen goes away: nothing keeps its graph, and profiling ends with its inspector.
    func test_dismissedSheet_endsProfilingSafely() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        let presenter = SheetPresenter()
        let harness = ScreenHarness(SheetHost(presenter: presenter))
        defer { harness.tearDown() }
        try await harness.waitUntilLoaded()
        presenter.isPresented = true
        try await waitUntil { InspectorPresenter.shared.frontmost?.renderCounts != nil }
        let session = try XCTUnwrap(InspectorPresenter.shared.frontmost)
        if session.renderCounts?.isGraphFound == false { throw XCTSkip("no view graph on this iOS version") }
        XCTAssertTrue(session.isProfiling)
        try await Task.sleep(for: .milliseconds(1200))   // a count read with the sheet's host on screen

        presenter.isPresented = false
        try await waitUntil { InspectorPresenter.shared.frontmost !== session }
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertFalse(session.isProfiling)
    }

    /// Not a check, a measurement: the cost of profiling while the Heavy home screen updates, and of reading counts.
    /// Writes `rerenders.overhead.txt` to `TEST_RUNNER_GOLDEN_OUT` when set.
    func test_overhead_heavyScreen() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        let harness = ScreenHarness(HeavyScreen())
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded(timeout: .seconds(30))
        let hosts = Self.hosts(in: harness.window)

        func spin(_ n: Int) -> Double {
            let start = CACurrentMediaTime()
            for i in 0..<n {
                harness.window.overrideUserInterfaceStyle = i % 2 == 0 ? .dark : .light
                harness.window.layoutIfNeeded()
            }
            return CACurrentMediaTime() - start
        }
        _ = spin(4)
        var plain: [Double] = [], profiled: [Double] = []
        let heatmap = RenderHeatmap()
        for _ in 0..<7 {
            plain.append(spin(20))
            heatmap.profiler.start(hosts: hosts)
            profiled.append(spin(20))
            heatmap.profiler.stop()
        }
        heatmap.profiler.start(hosts: hosts)
        defer { heatmap.profiler.stop() }
        try Self.skipWithoutGraph(heatmap)
        heatmap.map(capture)
        let map = heatmap.lastMapDuration
        var reads: [Double] = []
        for _ in 0..<5 { _ = spin(1); _ = heatmap.read(); reads.append(heatmap.lastReadDuration) }

        func ms(_ v: [Double]) -> String { v.map { String(format: "%.1f", $0 * 1000) }.joined(separator: " / ") }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        let text = """
            heavy screen, 20 forced updates (light/dark), 7 alternating rounds
            plain ms: \(ms(plain)), median \(ms([median(plain)]))
            profiled ms: \(ms(profiled)), median \(ms([median(profiled)]))
            map (once per capture) ms: \(ms([map]))
            read counts ms: \(ms(reads))
            components counted: \(heatmap.read().byNode.count)
            """
        print(text)
        if let out = ProcessInfo.processInfo.environment["GOLDEN_OUT"] {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try text.write(toFile: out + "/rerenders.overhead.txt", atomically: true, encoding: .utf8)
        }
    }

    // MARK: -

    /// Counts of every view titled `title`, top to bottom.
    private static func count(of title: String, in capture: InspectorCapture, _ counts: RenderCounts) -> [Int] {
        capture.swiftUINodes.filter { $0.kind == .component && $0.title == title }
            .sorted { $0.anchor.rect.minY < $1.anchor.rect.minY }
            .map { counts.byNode[$0.id]?.count ?? -1 }
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        for subview in view.subviews { if let found = scrollView(in: subview) { return found } }
        return nil
    }

    /// Mapping in steps, as the inspector does it on screen: the matcher runs in the background and the main thread only
    /// reads the forest a host at a time and the strings the matcher asks for. Same matches as mapping at once.
    func test_mapInSteps_keepsStepsShortAndMatchesTheSame() async throws {
        guard RenderProfiler.isAvailable else { throw XCTSkip("AttributeGraph profiling is not available") }
        let harness = ScreenHarness(MarketsScreen(model: MarketsModel(), showsShimmer: false))
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        let heatmap = RenderHeatmap()
        heatmap.profiler.start(hosts: Self.hosts(in: harness.window))
        defer { heatmap.profiler.stop() }
        try Self.skipWithoutGraph(heatmap)
        let direct = ComponentGraph.match(capture)

        ComponentGraph.forgetMatches()
        heatmap.beginMap(capture)
        var frames = 0
        while !heatmap.mapStep() {
            frames += 1
            try await Task.sleep(for: .milliseconds(2))
            XCTAssertLessThan(frames, 5000, "mapping never ends")
            if frames >= 5000 { return }
        }
        let parts = heatmap.lastMapParts
        print("RerenderTests map in steps: \(frames) frames, longest step \(Int(parts.longestStep * 1000)) ms, match on main "
              + "\(Int(parts.match * 1000)) ms in \(parts.matchRuns) runs, wall \(Int(parts.wall * 1000)) ms")
        XCTAssertGreaterThanOrEqual(parts.matchRuns, 1)
        XCTAssertLessThan(parts.longestStep, 0.07, "longest main-thread step of the mapping")
        let stepped = try XCTUnwrap(ComponentGraph.cachedMatch(of: capture))
        XCTAssertEqual(Set(stepped.keys), Set(direct.keys))
        for (id, match) in direct {
            XCTAssertEqual(stepped[id]?.views.map(\.valueNode), match.views.map(\.valueNode), "component \(id)")
        }
    }

    private static func skipWithoutGraph(_ heatmap: RenderHeatmap) throws {
        if !heatmap.profiler.hasGraphs { throw XCTSkip("no view graph on this iOS version (iOS 18): nothing to count") }
    }

    private static func hosts(in window: UIWindow) -> [UIView] {
        LayoutCapture.visibleHostingViews(in: window, excluding: [])
    }

    /// The child walk that asks AttributeGraph about hung subgraphs only where one can hang (``ChildReader``) gives
    /// every element the children the plain walk gives: on every demo screen (lazy stacks and grids, ForEach, a Form,
    /// hosted UIKit), after lazy rows scrolled in and out, under a pushed screen and with a sheet up. Skipping the
    /// search where it is needed loses the rows of a lazy list, which this sees as elements whose children differ.
    func test_childWalk_givesThePlainWalksChildren() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("no AttributeGraph tree walk on iOS 18") }
        print("WalkCheck code \(ChildReader.codeHashes.map { String($0, radix: 16) })")
        // Known: the iOS 26.5 and 27.0 simulators, which the release is tested on. Elsewhere trees are read the plain way.
        guard ChildReader.isAvailable else { throw XCTSkip("the child walk doesn't know this AttributeGraph") }
        func check(_ window: UIWindow, _ label: String) {
            let hosts = LayoutCapture.visibleHostingViews(in: window, excluding: [])
            XCTAssertFalse(hosts.isEmpty, label)
            for host in hosts {
                guard let result = ChildReader.check(host) else {
                    // Only a host without a tree (a UIKit bar item) may have no walk.
                    XCTAssertNil(AttributeGraphTree.tree(of: host), "\(label): no walk for \(type(of: host))")
                    continue
                }
                print("WalkCheck \(label) \(type(of: host)): \(result.elements) elements, \(result.mismatches) differ, "
                      + "\(result.searched) searched, \(result.roots) roots")
                XCTAssertGreaterThan(result.elements, 1, label)
                XCTAssertEqual(result.mismatches, 0, "\(label): \(type(of: host))")
            }
        }
        for screen in DemoScreen.allCases {
            let harness = ScreenHarness(screen.view)
            defer { harness.tearDown() }
            // Some screens animate for ever: the walk is checked on whatever is there by then.
            _ = try? await LayoutInspector.captureWhenStable(harness.window, timeout: .seconds(8))
            check(harness.window, screen.title)
            // Lazy rows built while scrolling, and the first ones left behind.
            if let scroll = Self.scrollViews(in: harness.window).max(by: { $0.contentSize.height < $1.contentSize.height }),
               scroll.contentSize.height > scroll.bounds.height * 1.5 {
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                try await Task.sleep(for: .milliseconds(400))
                check(harness.window, screen.title + " scrolled")
                scroll.setContentOffset(.zero, animated: false)
                try await Task.sleep(for: .milliseconds(400))
                check(harness.window, screen.title + " back")
            }
        }
        let presenter = SheetPresenter()
        let harness = ScreenHarness(WalkProbe(presenter: presenter))
        defer { harness.tearDown() }
        try await harness.waitUntilLoaded(timeout: .seconds(20))
        presenter.isPushed = true
        try await Task.sleep(for: .milliseconds(1200))
        check(harness.window, "pushed")
        presenter.isPresented = true
        try await Task.sleep(for: .milliseconds(1500))
        check(harness.window, "sheet")
        presenter.isPresented = false
        try await Task.sleep(for: .milliseconds(1200))
        check(harness.window, "sheet dismissed")
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func waitUntil(timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met in \(timeout)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class SheetPresenter: ObservableObject {
    @Published var isPresented = false
    @Published var isPushed = false
}

/// A list screen with another list pushed over it and a third in a sheet.
private struct WalkProbe: View {
    @ObservedObject var presenter: SheetPresenter

    var body: some View {
        LabelsScreen()
            .navigationDestination(isPresented: $presenter.isPushed) { FeedScreen() }
            .sheet(isPresented: $presenter.isPresented) { NavigationStack { MarketsScreen() } }
    }
}

private struct SheetHost: View {
    @ObservedObject var presenter: SheetPresenter

    var body: some View {
        Text("Presenter")
            .sheet(isPresented: $presenter.isPresented) {
                NavigationStack { RerenderScreen() }.layoutInspector(.rerenders)
            }
    }
}

