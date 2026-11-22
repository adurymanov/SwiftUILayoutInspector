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
        "big-app-portfolio.json": 0.05,
        "big-app-home.json": 0.05,
        "big-app-grid.json": 0.05,
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

    /// The matcher ties every bundled recording as it did when `Fixtures/MatchExpected` was written (component index →
    /// view indices). Written by the 0.2.15 matcher; against 0.2.14 it ties more components by their texts away from
    /// the nearest component (a list row's price is the one view built with that price, not a card's elsewhere), and a
    /// component left alone with several views gets none.
    func test_bundledRecordings_matchAsBefore() throws {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/MatchExpected")
        for url in Self.fixtures where url.deletingLastPathComponent().lastPathComponent == "Match" {
            let input = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)).input
            let before = try JSONDecoder().decode([String: [Int]].self,
                                                  from: Data(contentsOf: expected.appendingPathComponent(url.lastPathComponent)))
            let now = Dictionary(uniqueKeysWithValues: ComponentMatcher(input).run().map { (String($0.key), $0.value) })
            XCTAssertEqual(now, before, url.lastPathComponent)
        }
    }

    /// A total is shared by the components that can't be told apart, two or more: a component alone with several views
    /// gets no count (0.2.14 filled the panel with lines like "Σ0 shared by 1 view" on a big app's home).
    func test_recordings_shareOnlyBetweenComponents() throws {
        for url in Self.fixtures {
            let input = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)).input
            var holders: [[Int]: Int] = [:]
            for views in ComponentMatcher(input).run().values where views.count > 1 { holders[views.sorted(), default: 0] += 1 }
            XCTAssertEqual(holders.values.filter { $0 < 2 }.count, 0, url.lastPathComponent)
        }
        let box = [0.0, 0, 100, 20]
        let views = [MatchInput.View(type: "Row", host: 0, frame: [0, 0, 100, 40], bounds: [0, 0, 100, 40]),
                     MatchInput.View(type: "Label", parent: 0, host: 0, bounds: [0, 0, 50, 20]),
                     MatchInput.View(type: "Label", parent: 0, host: 0, bounds: [50, 0, 50, 20])]
        let one = MatchInput(views: views, components: [
            .init(id: 1, type: "Row", host: 0, box: [0, 0, 100, 40], texts: []),
            .init(id: 2, type: "Label", parent: 0, host: 0, box: box, texts: []),
        ])
        XCTAssertEqual(ComponentMatcher(one).run(), [0: [0]], "a label alone with two views")
        var two = one
        two.components.append(.init(id: 3, type: "Label", parent: 0, host: 0, box: box, texts: []))
        XCTAssertEqual(ComponentMatcher(two).run(), [0: [0], 1: [1, 2], 2: [1, 2]], "two labels that can't be told apart")
    }

    /// The matcher off the main thread asks about the strings it needs and is run again until it asked about none
    /// it didn't have (``ComponentGraph/MatchJob``): it ends with what reading them as it goes gives.
    func test_runsAskingForStrings_endAsMatchingAtOnce() throws {
        for url in Self.fixtures {
            let input = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)).input
            var known: [Int: Set<String>] = [:]
            var runs = 0
            var result: [Int: [Int]] = [:]
            while true {
                runs += 1
                let (assigned, missing) = ComponentGraph.MatchJob.run(input, known: known)
                result = assigned
                if missing.isEmpty || runs > 50 { break }
                for index in missing { known[index] = Set(input.views[index].strings ?? []) }
            }
            print("MatchReplay \(url.lastPathComponent): \(runs) runs, \(known.count) views' strings read")
            XCTAssertLessThanOrEqual(runs, 50, url.lastPathComponent)
            XCTAssertEqual(result, ComponentMatcher(input).run(), url.lastPathComponent)
        }
    }

    /// The matcher on the biggest recording (a big app's home after a scroll, 528 components, 1436 views) in a debug
    /// build, as apps build the library: it was 220-450 ms in 0.2.13, now a fraction of that and off the main thread.
    func test_bigRecording_matchesQuickly() throws {
        let url = try XCTUnwrap(Self.fixtures.first { $0.lastPathComponent == "big-app-portfolio.json" })
        let input = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)).input
        var best = Double.infinity
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = ComponentMatcher(input).run()
            best = min(best, CFAbsoluteTimeGetCurrent() - start)
        }
        print("MatchReplay big-app-portfolio.json: \(Int(best * 1000)) ms")
        XCTAssertLessThan(best, 0.15, "matching the biggest recording")
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
