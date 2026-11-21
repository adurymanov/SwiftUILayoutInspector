import SwiftUI
import XCTest
@_spi(Diagnostics) @testable import LayoutInspector
@testable import InspectorDemo

/// Dev → Components list: rows, details of a component, the same data in `capture.json`.
@MainActor
final class ComponentListTests: XCTestCase {
    override func tearDown() async throws {
        LayoutInspector.hide()
        try await super.tearDown()
    }

    func test_rows_inScreenOrder_withNesting() async throws {
        let harness = ScreenHarness(RerenderScreen())
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        try XCTSkipIf(capture.nodes(.component).isEmpty, "no component names on this iOS version (iOS 18)")
        let list = ComponentList(capture)
        let rows = list.rows.map { "\(String(repeating: " ", count: $0.depth))\($0.node.title)" }
        XCTAssertEqual(rows.filter { $0.contains("QuoteRow") }.count, 3, rows.joined(separator: "\n"))
        XCTAssertLessThan(try XCTUnwrap(rows.firstIndex { $0.contains("WalletBalance") }),
                          try XCTUnwrap(rows.firstIndex { $0.contains("QuoteRow") }))
        let screen = try XCTUnwrap(list.rows.first { $0.node.title == "RerenderScreen" })
        let row = try XCTUnwrap(list.rows.first { $0.node.title == "WalletBalance" })
        XCTAssertEqual(row.depth, screen.depth + 1)
        XCTAssertEqual(list.filtered("quote").count, 3)
        XCTAssertTrue(list.text(counts: nil).contains("QuoteRow  @ "))
    }

    /// Properties as the parent built the view, one view of a `ForEach` told apart from the others.
    func test_details_ofOneRow() async throws {
        let harness = ScreenHarness(RerenderScreen())
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        let matches = ComponentGraph.match(capture)
        try XCTSkipIf(matches.isEmpty, "no view graph on this iOS version")

        let rows = capture.swiftUINodes.filter { $0.title == "QuoteRow" }.sorted { $0.anchor.rect.minY < $1.anchor.rect.minY }
        let second = ComponentDetails.read(rows[1], match: matches[rows[1].id])
        XCTAssertNil(second.note)
        XCTAssertEqual(second.properties.first { $0.name == "index" }?.value, "1")
        XCTAssertTrue(second.properties.first { $0.name == "quote" }?.value?.contains("price: 80") == true,
                      second.properties.map(\.line).joined(separator: "\n"))

        let counter = try XCTUnwrap(capture.swiftUINodes.first { $0.title == "TapCounter" }, "TapCounter is not a named component")
        let state = ComponentDetails.read(counter, match: matches[counter.id]).properties
        XCTAssertEqual(state.filter { $0.kind == .state }.map(\.line).sorted(), ["@State label: String", "@State taps: Int"])

        let badge = try XCTUnwrap(capture.swiftUINodes.first { $0.title == "InboxBadge" })
        let badgeDetails = ComponentDetails.read(badge, match: matches[badge.id])
        XCTAssertEqual(badgeDetails.properties.first { $0.kind == .environment }?.line, "@Environment colorScheme: ColorScheme")
        XCTAssertTrue(badgeDetails.environment.contains { $0.name == "dynamicTypeSize" })
        XCTAssertTrue(badgeDetails.fonts.contains { $0.font.hasPrefix("Body") }, "\(badgeDetails.fonts)")
    }

    func test_captureJSON_hasProperties() async throws {
        let harness = ScreenHarness(RerenderScreen())
        defer { harness.tearDown() }
        let capture = try await harness.waitUntilLoaded()
        try XCTSkipIf(ComponentGraph.match(capture).isEmpty, "no view graph on this iOS version")
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

    /// The sheet opens from the inspector's window and a row selects its component.
    func test_sheet_opensAndSelects() async throws {
        let harness = ScreenHarness(RerenderScreen().layoutInspector(.components))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeCapture != nil }
        try XCTSkipIf(LayoutInspector.activeCapture?.nodes(.component).isEmpty == true, "no component names on this iOS version (iOS 18)")
        try await waitUntil { LayoutInspector.activeCapture?.find("WalletBalance", kind: .component) != nil }
        let session = try XCTUnwrap(InspectorPresenter.shared.frontmost)
        let root = try XCTUnwrap(session.window?.root)
        root.presentComponentList()
        try await waitUntil { root.presentedViewController != nil }
        let balance = try XCTUnwrap(session.capture?.find("WalletBalance", kind: .component))
        session.select(balance)
        XCTAssertEqual(session.selectedNode?.title, "WalletBalance")
        root.presentedViewController?.dismiss(animated: false)
        try await waitUntil { root.presentedViewController == nil }
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
