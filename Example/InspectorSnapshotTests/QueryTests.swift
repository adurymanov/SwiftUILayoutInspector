import SwiftUI
import XCTest
import LayoutInspector
@testable import InspectorDemo

/// Layout assertions without pixels: what a screen's test can check with `LayoutInspector.captureWhenStable`.
@MainActor
final class QueryTests: XCTestCase {
    func test_profile() async throws {
        let harness = ScreenHarness(DemoScreen.profile.view)
        defer { harness.tearDown() }
        let layout = try await harness.waitUntilLoaded()

        let header = try XCTUnwrap(layout.find("ProfileHeader", kind: .component))
        let row = try XCTUnwrap(header.descendants(.stack).first { $0.stack?.axis == .horizontal })
        XCTAssertEqual(row.stack?.spacing, 14)
        XCTAssertEqual(row.measuredGaps.first, 14, "avatar → name")

        let name = try XCTUnwrap(layout.find("Anna Petrova", kind: .text))
        XCTAssertEqual(name.font?.displayName, "Title 2 22pt Bold")
        XCTAssertEqual(name.font?.size, 22)
        XCTAssertEqual(name.font?.isDynamicType, true)
        XCTAssertEqual(name.enclosingComponent?.title, "ProfileHeader")

        let bio = try XCTUnwrap(layout.nodes(.text).first { $0.text?.string.hasPrefix("Product designer") == true })
        XCTAssertEqual(bio.text?.isTruncated, true)
        XCTAssertEqual(bio.text?.lineCount, 3)

        let content = try XCTUnwrap(layout.nodes(.padding).first { $0.padding?.declared?.leading == 16 })
        XCTAssertEqual(content.padding?.measured.leading, 16)
        XCTAssertEqual(content.padding?.measured.trailing, 16)
    }

    func test_dashboard_lint() async throws {
        let harness = ScreenHarness(DemoScreen.dashboard.view)
        defer { harness.tearDown() }
        let layout = try await harness.waitUntilLoaded()

        let messages = layout.lintIssues().map(\.message)
        XCTAssertTrue(messages.contains { $0.hasPrefix("Font 11.5pt is not in the type scale") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.hasPrefix("Tap target 32×32 < 44") }, "\(messages)")

        var relaxed = LayoutInspector.LintRules()
        relaxed.typeScale = []
        relaxed.minTapTarget = 32
        let relaxedMessages = layout.lintIssues(rules: relaxed).map(\.message)
        XCTAssertFalse(relaxedMessages.contains { $0.hasPrefix("Font 11.5pt") }, "\(relaxedMessages)")
        XCTAssertFalse(relaxedMessages.contains { $0.hasPrefix("Tap target") }, "\(relaxedMessages)")
    }

    func test_captureWhenStable_timesOut() async throws {
        let harness = ScreenHarness(ProgressView("Never loads"))
        defer { harness.tearDown() }
        do {
            _ = try await LayoutInspector.captureWhenStable(harness.window, timeout: .milliseconds(800))
            XCTFail("expected a timeout")
        } catch let error as LayoutInspector.CaptureTimeoutError {
            XCTAssertTrue(error.lastReport.contains("ProgressView"), error.lastReport)
        }
    }
}
