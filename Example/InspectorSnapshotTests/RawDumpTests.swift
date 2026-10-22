import XCTest
import SwiftUI
@_spi(Diagnostics) import LayoutInspector
@testable import InspectorDemo

/// Diagnostics, not a real test: dumps raw `_ViewDebug` JSON and the component reconstruction log.
/// Run with `TEST_RUNNER_RAW_DUMP=1`.
@MainActor
final class RawDumpTests: XCTestCase {
    func test_dump() async throws {
        guard ProcessInfo.processInfo.environment["RAW_DUMP"] != nil else { throw XCTSkip("set RAW_DUMP=1") }
        let dir = URL(fileURLWithPath: "/tmp/li-raw")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for screen in DemoScreen.allCases {
            let harness = ScreenHarness(screen.view)
            defer { harness.tearDown() }
            try await harness.waitUntilLoaded(timeout: .seconds(5))
            _ = harness.capture()
            try (LayoutInspector.lastCaptureTimings + LayoutInspector.lastReconstructionLog).joined(separator: "\n")
                .write(to: dir.appendingPathComponent("recon-\(screen.rawValue).txt"), atomically: true, encoding: .utf8)
        }
    }
}
