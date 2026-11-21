import XCTest
import SwiftUI
@_spi(Diagnostics) import LayoutInspector
@testable import InspectorDemo

/// Timing guard: a fresh capture of the heavy screen (thousands of conformances, long modifier chains, large models)
/// must stay quick in every step, the component index and placement included. 0.2.4 took seconds on a large app's
/// screen in the index and nothing in the suite noticed; placement there was ten times what 0.2.3 needed. Limits:
/// `TEST_RUNNER_TIMING_LIMIT_MS` (longest step, default 250), `TEST_RUNNER_INDEX_LIMIT_MS` (component index, 100) and
/// `TEST_RUNNER_APPLY_LIMIT_MS` (placement, 40); generous for a simulator, far below a regression.
@MainActor
final class CaptureTimingTests: XCTestCase {
    func test_heavyScreen_freshCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let stepLimit = Int(environment["TIMING_LIMIT_MS"] ?? "") ?? 250
        let indexLimit = Int(environment["INDEX_LIMIT_MS"] ?? "") ?? 100
        let applyLimit = Int(environment["APPLY_LIMIT_MS"] ?? "") ?? 40
        let harness = ScreenHarness(DemoScreen.heavy.view)
        defer { harness.tearDown() }
        try await harness.waitUntilLoaded(timeout: .seconds(20))

        var worst: (step: Int, index: Int, apply: Int) = (0, 0, 0)
        for _ in 0..<3 {
            LayoutInspector.resetCaptureCache()
            _ = await LayoutInspector.captureInSlices(harness.window)
            let timings = LayoutInspector.lastCaptureTimings
            let step = Self.milliseconds(in: timings, prefix: "longest step ")
            let index = Self.milliseconds(in: timings, prefix: "reconstructIndex ")
            let apply = Self.milliseconds(in: timings, prefix: "reconstructApply ")
            print("CaptureTimingTests: " + timings.joined(separator: ", "))
            let log = LayoutInspector.lastReconstructionLog
            print("CaptureTimingTests: log \(log.count) lines, anchored \(log.filter { $0.contains(": anchor ") && !$0.contains("ambiguous") }.count), "
                  + "no anchor \(log.filter { $0.hasSuffix(": no anchor") }.count)")
            worst = (max(worst.step, step ?? 0), max(worst.index, index ?? 0), max(worst.apply, apply ?? 0))
            XCTAssertNotNil(step, "no longest step in \(timings)")
            // iOS 18 has no AttributeGraph tree to rebuild components from, so there is no index to time there.
            if #available(iOS 26, *) {
                XCTAssertNotNil(index, "no component index in \(timings)")
                XCTAssertNotNil(apply, "no component placement in \(timings)")
                // The long modifier chains made 0.2.4 slow: they must be on screen and in the index.
                XCTAssertTrue(log.contains { $0.hasPrefix("ChainedBalanceRow:") }, "heavy chains not captured: \(log.prefix(20))")
            }
        }
        XCTAssertLessThan(worst.step, stepLimit, "longest step of a fresh capture of the heavy screen")
        XCTAssertLessThan(worst.index, indexLimit, "component index of a fresh capture of the heavy screen")
        XCTAssertLessThan(worst.apply, applyLimit, "component placement of a fresh capture of the heavy screen")
    }

    static func milliseconds(in timings: [String], prefix: String) -> Int? {
        timings.first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count).prefix { $0.isNumber }) }
    }
}
