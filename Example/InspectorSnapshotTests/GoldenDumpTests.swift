import XCTest
import SwiftUI
@_spi(Diagnostics) import LayoutInspector
@testable import InspectorDemo

/// Diagnostics, not a real test: writes everything each demo screen's capture holds (`LayoutInspector.dump`)
/// and the step timings of fresh captures, to diff a change to the capture code against the code before it.
/// Run with `TEST_RUNNER_GOLDEN_OUT=<dir>`.
@MainActor
final class GoldenDumpTests: XCTestCase {
    func test_dump() async throws {
        guard let out = ProcessInfo.processInfo.environment["GOLDEN_OUT"] else { throw XCTSkip("set GOLDEN_OUT=<dir>") }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runs = Int(ProcessInfo.processInfo.environment["GOLDEN_RUNS"] ?? "") ?? 3
        for screen in DemoScreen.allCases {
            let harness = ScreenHarness(screen.view)
            defer { harness.tearDown() }
            try await harness.waitUntilLoaded(timeout: .seconds(20))
            var timings: [String] = []
            var dump = ""
            var log = ""
            for run in 0..<runs {
                LayoutInspector.resetCaptureCache()
                let capture = harness.capture()
                timings.append("fresh \(run): " + LayoutInspector.lastCaptureTimings.joined(separator: ", "))
                let text = LayoutInspector.dump(capture)
                if run == 0 { dump = text; log = LayoutInspector.lastReconstructionLog.joined(separator: "\n") } else if text != dump { timings.append("fresh \(run): DUMP DIFFERS") }
            }
            LayoutInspector.resetCaptureCache()
            let sliced = await LayoutInspector.captureInSlices(harness.window)
            let slicedDump = LayoutInspector.dump(sliced)
            if slicedDump != dump {
                timings.append("sliced: DUMP DIFFERS")
                try slicedDump.write(to: dir.appendingPathComponent("\(screen.rawValue).sliced.dump.txt"), atomically: true, encoding: .utf8)
            }
            let cached = harness.capture()
            timings.append("cached: " + LayoutInspector.lastCaptureTimings.joined(separator: ", "))
            if LayoutInspector.dump(cached) != dump { timings.append("cached: DUMP DIFFERS") }
            try (dump + "\n# reconstruction\n" + log).write(to: dir.appendingPathComponent("\(screen.rawValue).dump.txt"),
                                                         atomically: true, encoding: .utf8)
            try timings.joined(separator: "\n").write(to: dir.appendingPathComponent("\(screen.rawValue).timings.txt"),
                                                      atomically: true, encoding: .utf8)
        }
    }
}
