import XCTest
import SwiftUI
@_spi(Diagnostics) import LayoutInspector
@testable import InspectorDemo

/// Diagnostics, not a real test: checks that the capture reads every hosting view's `_ViewDebug` data exactly as
/// SwiftUI's own JSON (`makeViewDebugData`) describes it: types, geometry and every value of every node.
/// Run with `TEST_RUNNER_GOLDEN_OUT=<dir>`; writes `<screen>.equivalence.txt`.
@MainActor
final class DebugDataEquivalenceTests: XCTestCase {
    func test_equivalence() async throws {
        guard let out = ProcessInfo.processInfo.environment["GOLDEN_OUT"] else { throw XCTSkip("set GOLDEN_OUT=<dir>") }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mismatches = 0
        for screen in DemoScreen.allCases {
            let harness = ScreenHarness(screen.view)
            defer { harness.tearDown() }
            try await harness.waitUntilLoaded(timeout: .seconds(20))
            var report: [String] = []
            for host in Self.hosts(in: harness.window) {
                let name = String(describing: type(of: host)).prefix(60)
                guard let fromData = LayoutInspector.debugDataDump(of: host) else { report.append("\(name): no data"); continue }
                if let parts = LayoutInspector.partLookupMismatches(of: host), !parts.isEmpty {
                    mismatches += 1
                    report.append("\(name): \(parts.count) part lookups differ")
                    report += parts.prefix(10).map { "  " + $0 }
                }
                guard let fromJSON = Self.jsonDump(of: host) else {
                    report.append("\(name): JSON failed, \(fromData.split(separator: "\n").count) nodes read")
                    continue
                }
                if fromJSON == fromData {
                    report.append("\(name): equal, \(fromData.split(separator: "\n").count) nodes")
                } else {
                    mismatches += 1
                    let a = fromJSON.split(separator: "\n", omittingEmptySubsequences: false)
                    let b = fromData.split(separator: "\n", omittingEmptySubsequences: false)
                    report.append("\(name): DIFFERENT, json \(a.count) lines, data \(b.count) lines")
                    var shown = 0
                    for i in 0..<max(a.count, b.count) where shown < 10 {
                        let l = i < a.count ? String(a[i]) : "<none>", r = i < b.count ? String(b[i]) : "<none>"
                        if l != r {
                            let common = zip(l, r).prefix { $0 == $1 }.count
                            let start = max(0, common - 250)
                            report.append("  line \(i) at \(common): " + String(l.dropFirst(start).prefix(150)).trimmingCharacters(in: .whitespaces))
                            report.append("    json: " + String(l.dropFirst(common).prefix(300)))
                            report.append("    data: " + String(r.dropFirst(common).prefix(300)))
                            shown += 1
                        }
                    }
                }
            }
            try report.joined(separator: "\n").write(to: dir.appendingPathComponent("\(screen.rawValue).equivalence.txt"),
                                                    atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(mismatches, 0)
    }

    static func hosts(in view: UIView) -> [UIView] {
        var result: [UIView] = []
        if view.responds(to: NSSelectorFromString("makeViewDebugData")) { result.append(view) }
        for sub in view.subviews { result += hosts(in: sub) }
        return result
    }

    /// The same lines from SwiftUI's JSON, read the way the capture used to read it (0.2.1).
    static func jsonDump(of host: UIView) -> String? {
        guard let data = host.perform(NSSelectorFromString("makeViewDebugData"))?.takeUnretainedValue() as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var lines: [String] = []
        func point(_ attr: [String: Any]?) -> CGPoint? {
            guard let a = attr?["value"] as? [NSNumber], a.count == 2 else { return nil }
            return CGPoint(x: CGFloat(truncating: a[0]), y: CGFloat(truncating: a[1]))
        }
        func visit(_ node: [String: Any], _ depth: Int) {
            var attrs: [Int: [String: Any]] = [:]
            for property in node["properties"] as? [[String: Any]] ?? [] {
                if let id = (property["id"] as? NSNumber)?.intValue, let a = property["attribute"] as? [String: Any] { attrs[id] = a }
            }
            let type = attrs[0]?["type"] as? String ?? attrs[1]?["type"] as? String ?? "?"
            let readable = attrs[0]?["readableType"] as? String ?? attrs[1]?["readableType"] as? String ?? "?"
            let size = point(attrs[4]).map { CGSize(width: $0.x, height: $0.y) }
            lines.append(LayoutInspector.debugDataDumpLine(depth: depth, type: type, readable: readable, origin: point(attrs[3]),
                                                           size: size, value: attrs[1]))
            for child in node["children"] as? [[String: Any]] ?? [] { visit(child, depth + 1) }
        }
        json.forEach { visit($0, 0) }
        return lines.joined(separator: "\n")
    }
}
