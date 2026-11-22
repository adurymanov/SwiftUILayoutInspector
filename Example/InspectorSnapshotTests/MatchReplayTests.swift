import CoreGraphics
import XCTest
@testable import LayoutInspector

/// Matching replayed on recordings of real screens (`LAYOUT_INSPECTOR_MATCH_DUMP`, anonymized with
/// `Tools/anonymize-match.py`): what the components and the graph looked like in an app the demo doesn't copy.
/// More recordings are read from `LAYOUT_INSPECTOR_MATCH_FIXTURES` (a directory) when it is set.
final class MatchReplayTests: XCTestCase {
    private struct Recording: Decodable {
        var input: MatchInput
    }

    /// The share of components with a count that may share it, by recording.
    private static let limits: [String: Double] = [
        "markets-demo.json": 0.05,
        "big-app-portfolio.json": 0.20,
        "big-app-home.json": 0.20,
    ]

    private static var fixtures: [URL] {
        let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Match")
        var dirs = [bundled]
        if let extra = ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_MATCH_FIXTURES"] { dirs.append(URL(fileURLWithPath: extra)) }
        return dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func test_recordings_shareFewCounts() throws {
        let fixtures = Self.fixtures
        XCTAssertFalse(fixtures.isEmpty, "no recordings")
        for url in fixtures {
            let input = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)).input
            let result = ComponentMatcher(input).run()
            let (views, own) = ComponentMatcher.summary(result)
            let share = Double(views - own) / Double(max(views, 1))
            print("MatchReplay \(url.lastPathComponent): \(views) views, \(own) own, \(views - own) shared")
            XCTAssertGreaterThan(views, 0, url.lastPathComponent)
            XCTAssertLessThanOrEqual(share, Self.limits[url.lastPathComponent] ?? 0.2, url.lastPathComponent)
            for (component, matched) in result where matched.count == 1 {
                XCTAssertTrue(Self.isPlausible(input, component, matched[0]),
                              "\(url.lastPathComponent): component \(component) tied to view \(matched[0]) that can't be it")
            }
        }
    }

    /// An exact pair has the same type, and the component's recorded box lies on what the view's `body` produced.
    private static func isPlausible(_ input: MatchInput, _ component: Int, _ view: Int) -> Bool {
        let c = input.components[component], v = input.views[view]
        guard c.type == v.type else { return false }
        guard let box = CGRect(c.box), let bounds = CGRect(v.bounds), box.width > 0, box.height > 0, bounds.width > 0,
              bounds.height > 0 else { return true }
        return box.insetBy(dx: -1, dy: -1).intersects(bounds)
    }
}
