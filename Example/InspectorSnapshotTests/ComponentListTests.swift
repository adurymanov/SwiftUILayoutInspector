import SwiftUI
import XCTest
@_spi(Diagnostics) @testable import LayoutInspector
@testable import InspectorDemo

/// Dev → Components list: folding, filters, picking a point, details, the same data in `capture.json`.
@MainActor
final class ComponentListTests: XCTestCase {
    override func tearDown() async throws {
        LayoutInspector.hide()
        try await super.tearDown()
    }

    private static let everything = ComponentList.Filter(visibleOnly: false, hidesWrappers: false, appTypesOnly: false)

    private func capture<V: View>(_ view: V) async throws -> (ScreenHarness, InspectorCapture) {
        let harness = ScreenHarness(view)
        let capture = try await harness.waitUntilLoaded(timeout: .seconds(20))
        capture.resolveFrames(in: harness.window)
        // iOS 18 names only a few views (a controller host), never the app's own screens.
        if !capture.nodes(.component).contains(where: { ["AccountStatementsHistoryScreenContent", "WalletBalance", "HeavyScreen"].contains($0.title) || $0.title.hasPrefix("Heavy") }) {
            harness.tearDown()
            throw XCTSkip("no component names on this iOS version (iOS 18)")
        }
        return (harness, capture)
    }

    private func list(_ capture: InspectorCapture) -> ComponentList {
        ComponentList(capture, modifierTypes: ComponentGraph.modifierTypes(in: capture))
    }

    /// Folding a same-size chain loses no component: each one is a row, a row's wrapper or a modifier hidden as such.
    func test_folding_keepsEveryComponent() async throws {
        let (harness, capture) = try await capture(DeepChainScreen())
        defer { harness.tearDown() }
        let modifiers = ComponentGraph.modifierTypes(in: capture)
        let list = list(capture)
        let all = Set(list.all.map { ObjectIdentifier($0.node) })
        let shown = Set(list.folded.flatMap { [$0.node] + $0.wrappers }.map(ObjectIdentifier.init))
        let hidden = list.all.map(\.node).filter { !shown.contains(ObjectIdentifier($0)) }
        XCTAssertTrue(shown.isSubset(of: all))
        XCTAssertTrue(hidden.allSatisfy { $0.kind == .customModifier || modifiers.contains($0.typeName) },
                      "hidden but not modifiers: \(hidden.map(\.title))")

        let rows = list.rows(ComponentList.Filter(), ComponentList.Context(bounds: harness.window.bounds))
        let screen = try XCTUnwrap(rows.first, list.text(rows, in: list.folded, counts: nil))
        XCTAssertEqual(screen.node.title, "AccountStatementsHistoryScreenContent", list.text(rows, in: list.folded, counts: nil))
        XCTAssertGreaterThanOrEqual(screen.wrappers.count, 8, screen.wrappers.map(\.title).joined(separator: " → "))
        XCTAssertFalse(rows.contains { $0.node.title.hasSuffix("Modifier") }, "a modifier is a row")
        let row = try XCTUnwrap(rows.first { $0.node.title == "TransactionHistoryRowWithMerchantLogoAndAmount" })
        XCTAssertEqual(row.parent.map { list.folded[$0].node.title }, "AccountStatementsHistoryScreenContent")
        XCTAssertTrue(list.folded[try XCTUnwrap(row.parent)].children.contains { list.folded[$0].node === row.node })
    }

    func test_filters() async throws {
        let (harness, capture) = try await capture(DeepChainScreen())
        defer { harness.tearDown() }
        let list = list(capture)
        let bounds = harness.window.bounds
        func titles(_ filter: ComponentList.Filter, _ context: ComponentList.Context) -> [String] {
            var context = context
            context.bounds = bounds
            return list.rows(filter, context).map(\.node.title)
        }

        let all = titles(Self.everything, .init())
        XCTAssertTrue(all.contains("AnalyticsImpressionTrackingZeroSizeAnchor") || !all.contains { $0.contains("ZeroSize") })
        var visible = Self.everything
        visible.visibleOnly = true
        XCTAssertFalse(titles(visible, .init()).contains("AnalyticsImpressionTrackingZeroSizeAnchor"), "zero-size views are not visible")
        XCTAssertLessThan(titles(visible, .init()).count, all.count)

        var module = Self.everything
        module.module = "SwiftUI"
        XCTAssertEqual(titles(module, .init()), [])
        module.module = "InspectorDemo"
        XCTAssertEqual(titles(module, .init()).count, all.count)

        XCTAssertEqual(Set(titles(Self.everything, .init(query: "merchant"))), ["TransactionHistoryRowWithMerchantLogoAndAmount"])
        XCTAssertEqual(titles(Self.everything, .init(query: "inspectordemo")).count, all.count, "the query matches the module")

        let first = try XCTUnwrap(list.all.first { $0.node.title == "StatementPeriodSummaryHeaderWithBalanceBreakdown" })
        var counts = RenderCounts()
        counts.byNode[first.node.id] = .init(count: 3, instances: 1)
        var rerendered = Self.everything
        rerendered.rerenderedOnly = true
        XCTAssertEqual(titles(rerendered, .init(counts: counts)), ["StatementPeriodSummaryHeaderWithBalanceBreakdown"])
        rerendered.rerenderedOnly = false
        rerendered.sort = .rerenders
        XCTAssertEqual(titles(rerendered, .init(counts: counts)).first, "StatementPeriodSummaryHeaderWithBalanceBreakdown")

        var byArea = visible
        byArea.sort = .area
        let areas = list.rows(byArea, .init(bounds: bounds)).map(\.node.frame.area)
        XCTAssertEqual(areas, areas.sorted(by: >))

        let stateful = ComponentListModel.statefulComponents(in: capture)
        var withState = Self.everything
        withState.statefulOnly = true
        let statefulTitles = Set(titles(withState, .init(stateful: stateful)))
        XCTAssertTrue(statefulTitles.contains("ScreenErrorStateOverlayContainer"), "\(statefulTitles)")
        XCTAssertFalse(statefulTitles.contains("TransactionHistoryRowWithMerchantLogoAndAmount"))
    }

    /// Controller hosts the size of their parent with nothing to show fold into the row, like wrappers.
    func test_hollowPresenters_areWrappers() async throws {
        let (harness, capture) = try await capture(DeepChainScreen())
        defer { harness.tearDown() }
        let list = list(capture)
        let hosts = list.all.filter { $0.node.title == "ModalControllerHost" }
        try XCTSkipIf(hosts.isEmpty, "the controller hosts are not named on this iOS version")
        let rows = list.rows(ComponentList.Filter(), .init(bounds: harness.window.bounds))
        XCTAssertFalse(rows.contains { $0.node.title == "ModalControllerHost" }, list.text(rows, in: list.folded, counts: nil))
        XCTAssertTrue(list.folded.contains { row in row.wrappers.contains { $0.title == "ModalControllerHost" } })
        XCTAssertEqual(rows.first?.node.title, "AccountStatementsHistoryScreenContent", list.text(rows, in: list.folded, counts: nil))
    }

    /// Siblings of one type next to each other become one row that opens with a tap.
    func test_runOfSiblings_isOneRow() async throws {
        let (harness, capture) = try await capture(DeepChainScreen())
        defer { harness.tearDown() }
        let list = list(capture)
        let filter = ComponentList.Filter()
        let context = ComponentList.Context(bounds: harness.window.bounds)
        let rows = list.rows(filter, context)
        let entries = list.entries(rows, filter: filter, context: context, expanded: [])
        let groups = entries.compactMap { entry -> (String, [ComponentList.Item])? in
            if case let .group(key, items) = entry { return (key, items) } else { return nil }
        }
        let group = try XCTUnwrap(groups.first { $0.1.first?.node.title == "TransactionHistoryRowWithMerchantLogoAndAmount" })
        let describe = entries.map { entry -> String in
            switch entry {
            case let .item(item): "\(item.node.title) p\(item.parent ?? -1) \(item.frame.frameLabel)"
            case let .group(key, items): "GROUP \(key) ×\(items.count)"
            case let .close(key, items): "OPEN \(key) ×\(items.count)"
            }
        }.joined(separator: "\n")
        // Rows behind the bottom bar come after it in reading order: a run of two stays as two rows.
        let single = entries.filter { if case let .item(item) = $0 { item.node.title == "TransactionHistoryRowWithMerchantLogoAndAmount" } else { false } }
        XCTAssertLessThanOrEqual(single.count, 2, describe)
        XCTAssertGreaterThanOrEqual(group.1.count, 8, describe)
        let opened = list.entries(rows, filter: filter, context: context, expanded: [group.0])
        XCTAssertEqual(opened.count, entries.count + group.1.count, "the opened run and a row that folds it again")
        var search = context
        search.query = "Transaction"
        XCTAssertTrue(list.entries(rows, filter: filter, context: search, expanded: []).allSatisfy { if case .item = $0 { true } else { false } })
    }

    /// The Module menu lists the screen's modules, keeps the rows of the one picked, and forgets a module the next
    /// screen doesn't have.
    func test_moduleFilter() async throws {
        let (harness, capture) = try await capture(DeepChainScreen())
        defer { harness.tearDown() }
        let model = ComponentListModel()
        model.filter = ComponentList.Filter(visibleOnly: false, hidesWrappers: false, appTypesOnly: false)
        model.update(capture)
        XCTAssertTrue(model.list.modules.contains("InspectorDemo"), "\(model.list.modules)")
        XCTAssertEqual(model.list.modules.first, "InspectorDemo", "the app's modules come first")
        let all = model.list.rows(model.filter, model.context(bounds: harness.window.bounds, counts: nil)).count
        model.filter.module = "InspectorDemo"
        XCTAssertEqual(model.list.rows(model.filter, model.context(bounds: harness.window.bounds, counts: nil)).count, all)

        let other = ScreenHarness(RerenderScreen())
        defer { other.tearDown() }
        let otherCapture = try await other.waitUntilLoaded()
        model.filter.module = "SomeModuleThatIsNotThere"
        model.update(otherCapture)
        XCTAssertNil(model.filter.module, "a module the screen doesn't have is dropped, or the list would be empty")
        model.filter = ComponentList.Filter()
    }

    /// The panel and the button stay above the app's own bar at the bottom.
    func test_panel_staysAboveBottomBar() async throws {
        let harness = ScreenHarness(DeepChainScreen().layoutInspector(.lint))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeCapture != nil && InspectorPresenter.shared.frontmost?.panel != nil }
        let session = try XCTUnwrap(InspectorPresenter.shared.frontmost)
        let barTop = try XCTUnwrap(session.bottomBarTop, "the bar of buttons at the bottom was not found")
        let root = try XCTUnwrap(session.window?.root)
        root.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        root.view.layoutIfNeeded()
        let panel = try XCTUnwrap(root.view.subviews.first { NSStringFromClass(type(of: $0)).contains("Hosting") && $0.frame.height > 20 && $0.frame.minX < 20 })
        XCTAssertLessThanOrEqual(panel.frame.maxY, barTop, "panel \(panel.frame) covers the bar at \(barTop)")
    }

    /// A point picked on screen keeps the components under it, smallest first.
    func test_pick_hitTesting() async throws {
        let (harness, capture) = try await capture(DeepChainScreen())
        defer { harness.tearDown() }
        let list = list(capture)
        let row = try XCTUnwrap(list.folded.first { $0.node.title == "TransactionHistoryRowWithMerchantLogoAndAmount" })
        let point = CGPoint(x: row.node.frame.midX, y: row.node.frame.midY)
        let picked = list.rows(ComponentList.Filter(), .init(bounds: harness.window.bounds, point: point))
        XCTAssertEqual(picked.first?.node.title, "TransactionHistoryRowWithMerchantLogoAndAmount")
        XCTAssertTrue(picked.allSatisfy { $0.frame.contains(point) })
        XCTAssertEqual(picked.map(\.frame.area), picked.map(\.frame.area).sorted())
        XCTAssertTrue(picked.contains { $0.node.title == "AccountStatementsHistoryScreenContent" })
    }

    /// Rows of a `ForEach` are told apart, and their details show what each was built with.
    func test_details_ofOneRow() async throws {
        let (harness, capture) = try await capture(RerenderScreen())
        defer { harness.tearDown() }
        let matches = ComponentGraph.match(capture)
        let rows = capture.swiftUINodes.filter { $0.title == "QuoteRow" }.sorted { $0.anchor.rect.minY < $1.anchor.rect.minY }
        let second = ComponentDetails.read(rows[1], match: matches[rows[1].id])
        XCTAssertNil(second.note)
        XCTAssertEqual(second.properties.first { $0.name == "index" }?.value, "1")
        XCTAssertTrue(second.properties.first { $0.name == "quote" }?.value?.contains("price: 80") == true,
                      second.properties.map(\.line).joined(separator: "\n"))

        let counter = try XCTUnwrap(capture.swiftUINodes.first { $0.title == "TapCounter" })
        let state = ComponentDetails.read(counter, match: matches[counter.id]).properties
        XCTAssertEqual(state.filter { $0.kind == .state }.map(\.line).sorted(), ["@State label: String", "@State taps: Int"])

        let badge = try XCTUnwrap(capture.swiftUINodes.first { $0.title == "InboxBadge" })
        let badgeDetails = ComponentDetails.read(badge, match: matches[badge.id])
        XCTAssertEqual(badgeDetails.properties.first { $0.kind == .environment }?.line, "@Environment colorScheme: ColorScheme")
        XCTAssertTrue(badgeDetails.environment.contains { $0.name == "dynamicTypeSize" })
    }

    func test_captureJSON_hasProperties() async throws {
        let (harness, capture) = try await capture(RerenderScreen())
        defer { harness.tearDown() }
        CaptureJSON.includesProperties = true
        defer { CaptureJSON.includesProperties = false }
        let json = CaptureJSON.object(for: capture, rules: .init(), bounds: harness.window.bounds, space: harness.window)
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let rows = nodes.filter { $0["title"] as? String == "QuoteRow" }
        let indexes = rows.compactMap { row in (row["properties"] as? [[String: Any]])?.first { $0["name"] as? String == "index" }?["value"] as? String }
        XCTAssertEqual(Set(indexes), ["0", "1", "2"])
        XCTAssertNotNil((json["environment"] as? [String: String])?["layoutDirection"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    /// The sheet opens from the inspector's window; a pick takes the next tap instead of the app.
    func test_sheet_picksAPoint() async throws {
        let harness = ScreenHarness(DeepChainScreen().layoutInspector(.components))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeCapture != nil }
        try XCTSkipIf(LayoutInspector.activeCapture?.nodes(.component).isEmpty == true, "no component names on this iOS version (iOS 18)")
        let session = try XCTUnwrap(InspectorPresenter.shared.frontmost)
        let root = try XCTUnwrap(session.window?.root)
        root.presentComponentList()
        try await waitUntil { root.presentedViewController != nil }

        var picked: CGPoint?
        session.pickPoint { picked = $0 }
        XCTAssertTrue(session.catchesTap(at: CGPoint(x: 100, y: 300)))
        session.handleTap(at: CGPoint(x: 100, y: 300))
        XCTAssertEqual(picked, CGPoint(x: 100, y: 300))
        XCTAssertFalse(session.catchesTap(at: CGPoint(x: 100, y: 300)), "only one tap is taken")

        root.dismissComponentList(animated: false)
        try await waitUntil { root.presentedViewController == nil }
    }

    /// Not a check, a measurement: building the list of the heavy screen (what opening the sheet costs).
    func test_openingCost_heavyScreen() async throws {
        let (harness, capture) = try await capture(HeavyScreen())
        defer { harness.tearDown() }
        var times: [Double] = []
        var rows = 0
        for _ in 0..<5 {
            let model = ComponentListModel()
            model.update(capture)
            rows = model.list.rows(ComponentList.Filter(), model.context(bounds: harness.window.bounds, counts: nil)).count
            times.append(model.buildDuration * 1000)
        }
        let stateful = CACurrentMediaTime()
        _ = ComponentListModel.statefulComponents(in: capture)
        let text = "heavy screen: list build ms \(times.map { String(format: "%.1f", $0) }.joined(separator: " / ")), "
            + "\(rows) rows of \(capture.nodes(.component).count) components; Has state read \(String(format: "%.1f", (CACurrentMediaTime() - stateful) * 1000)) ms"
        print(text)
        if let out = ProcessInfo.processInfo.environment["GOLDEN_OUT"] {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try text.write(toFile: out + "/components-list.cost.txt", atomically: true, encoding: .utf8)
        }
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
