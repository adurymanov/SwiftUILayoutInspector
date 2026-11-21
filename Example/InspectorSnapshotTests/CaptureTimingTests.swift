import XCTest
import SwiftUI
@_spi(Diagnostics) import LayoutInspector
@testable import InspectorDemo

/// Timing guard: a fresh capture of the heavy screen (thousands of conformances, long modifier chains, large models)
/// must stay quick in every step, the component index included. 0.2.4 took seconds on a large app's screen in that
/// step and nothing in the suite noticed. Limits: `TEST_RUNNER_TIMING_LIMIT_MS` (longest step, default 250) and
/// `TEST_RUNNER_INDEX_LIMIT_MS` (component index, default 100); generous for a simulator, far below a regression.
@MainActor
final class CaptureTimingTests: XCTestCase {
    func test_heavyScreen_freshCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let stepLimit = Int(environment["TIMING_LIMIT_MS"] ?? "") ?? 250
        let indexLimit = Int(environment["INDEX_LIMIT_MS"] ?? "") ?? 100
        let harness = ScreenHarness(DemoScreen.heavy.view)
        defer { harness.tearDown() }
        try await harness.waitUntilLoaded(timeout: .seconds(20))

        var worst: (step: Int, index: Int) = (0, 0)
        for _ in 0..<3 {
            LayoutInspector.resetCaptureCache()
            _ = await LayoutInspector.captureInSlices(harness.window)
            let timings = LayoutInspector.lastCaptureTimings
            let step = Self.milliseconds(in: timings, prefix: "longest step ")
            let index = Self.milliseconds(in: timings, prefix: "reconstructIndex ")
            print("CaptureTimingTests: " + timings.joined(separator: ", "))
            worst = (max(worst.step, step ?? 0), max(worst.index, index ?? 0))
            XCTAssertNotNil(step, "no longest step in \(timings)")
            // iOS 18 has no AttributeGraph tree to rebuild components from, so there is no index to time there.
            if #available(iOS 26, *) {
                XCTAssertNotNil(index, "no component index in \(timings)")
                // The long modifier chains made 0.2.4 slow: they must be on screen and in the index.
                let log = LayoutInspector.lastReconstructionLog
                XCTAssertTrue(log.contains { $0.hasPrefix("ChainedBalanceRow:") }, "heavy chains not captured: \(log.prefix(20))")
            }
        }
        XCTAssertLessThan(worst.step, stepLimit, "longest step of a fresh capture of the heavy screen")
        XCTAssertLessThan(worst.index, indexLimit, "component index of a fresh capture of the heavy screen")
    }

    static func milliseconds(in timings: [String], prefix: String) -> Int? {
        timings.first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count).prefix { $0.isNumber }) }
    }
}
