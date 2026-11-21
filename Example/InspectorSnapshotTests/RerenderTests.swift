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
        for _ in 0..<5 { _ = heatmap.read(); reads.append(heatmap.lastReadDuration) }

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

    private static func skipWithoutGraph(_ heatmap: RenderHeatmap) throws {
        if !heatmap.profiler.hasGraphs { throw XCTSkip("no view graph on this iOS version (iOS 18): nothing to count") }
    }

    private static func hosts(in window: UIWindow) -> [UIView] {
        LayoutCapture.visibleHostingViews(in: window, excluding: [])
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
