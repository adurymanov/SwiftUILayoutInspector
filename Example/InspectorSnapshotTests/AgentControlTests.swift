import SwiftUI
import XCTest
@_spi(Diagnostics) import LayoutInspector
@testable import InspectorDemo

/// Commands from the Mac (Darwin notifications), the report files, `capture.json` and the numbers `li` reads from it.
@MainActor
final class AgentControlTests: XCTestCase {
    override func tearDown() async throws {
        LayoutInspector.hide()
        try await super.tearDown()
    }

    // MARK: - Commands

    func test_commands_switchModesShowAndClose() async throws {
        let before = LayoutInspector.agentCommandCount

        post("dev.layoutinspector.mode.spacing")
        try await waitUntil("spacing shown") { LayoutInspector.isVisible && LayoutInspector.activeConfiguration?.mode == .spacing }

        // Scoped to this app's bundle id.
        post("dev.layoutinspector.\(Bundle.main.bundleIdentifier!).mode.typography")
        try await waitUntil("fonts") { LayoutInspector.activeConfiguration?.mode == .typography }

        post("dev.layoutinspector.close")
        try await waitUntil("closed") { !LayoutInspector.isVisible }

        // A mode command brings the closed inspector back.
        post("dev.layoutinspector.mode.lint")
        try await waitUntil("shown again") { LayoutInspector.isVisible && LayoutInspector.activeConfiguration?.mode == .lint }

        // The scoped name of a command that changes nothing: the bundle prefix is stripped, the mode stays.
        let count = LayoutInspector.agentCommandCount
        post("dev.layoutinspector.\(Bundle.main.bundleIdentifier!).status")
        try await waitUntil("status") { LayoutInspector.agentCommandCount == count + 1 }
        XCTAssertEqual(LayoutInspector.activeConfiguration?.mode, .lint)
        XCTAssertEqual(LayoutInspector.agentCommandCount - before, 5)
    }

    func test_modeCommand_writesFilesForAFreshCapture() async throws {
        post("dev.layoutinspector.mode.spacing")
        try await waitUntil("shown") { LayoutInspector.isVisible }
        let dir = try XCTUnwrap(LayoutInspector.reportDirectory)
        let number = LayoutInspector.agentCommandCount
        var status: [String: Any] = [:]
        try await waitUntil("capture after the command", timeout: 15) {
            LayoutInspector.flushReports()
            status = Self.json(dir.appendingPathComponent("status.json")) ?? [:]
            return ((status["capture"] as? [String: Any])?["afterCommand"] as? Int ?? -1) >= number
        }
        XCTAssertEqual(status["schemaVersion"] as? Int, 1)
        XCTAssertEqual(status["library"] as? String, LayoutInspector.version)
        XCTAssertEqual((status["command"] as? [String: Any])?["name"] as? String, "mode.spacing")
        XCTAssertEqual((status["inspector"] as? [String: Any])?["kind"] as? String, "window")
        let capture = try XCTUnwrap(status["capture"] as? [String: Any])
        XCTAssertEqual(capture["mode"] as? String, "spacing")
        XCTAssertNotNil(capture["duration"] as? Double)
        let json = try XCTUnwrap(Self.json(dir.appendingPathComponent("capture.json")))
        XCTAssertEqual(((json["capture"] as? [String: Any])?["number"] as? Int), capture["number"] as? Int,
                       "status.json is written last and names the capture in capture.json")
        let report = try String(contentsOf: dir.appendingPathComponent("report.txt"), encoding: .utf8)
        XCTAssertTrue(report.hasPrefix("# Layout report"), report)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Files

    func test_atomicWrite_readerNeverSeesHalfAFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("li-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("status.json")
        let big = Array(repeating: "x", count: 200_000).joined()
        let reader = Task.detached { () -> (reads: Int, broken: Int) in
            var reads = 0, broken = 0
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                guard let data = FileManager.default.contents(atPath: url.path) else { continue }
                reads += 1
                if (try? JSONSerialization.jsonObject(with: data)) == nil { broken += 1 }
            }
            return (reads, broken)
        }
        for i in 0..<150 {
            let data = try JSONSerialization.data(withJSONObject: ["n": i, "payload": String(big.prefix(1000 * (i % 200 + 1)))])
            LayoutInspector.writeAtomically(data, to: url)
            try await Task.sleep(for: .milliseconds(5))
        }
        let result = await reader.value
        XCTAssertGreaterThan(result.reads, 10)
        XCTAssertEqual(result.broken, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["status.json"])
    }

    // MARK: - capture.json

    func test_snapshotJSON_schemaAndNumbers() async throws {
        let snapshot = await LayoutInspector.snapshot(NavigationStack { ProfileScreen() })
        defer { snapshot.close() }
        XCTAssertTrue(snapshot.isStable)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.json()) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["library"] as? String, LayoutInspector.version)
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0["id"] as! Int, $0) })
        for node in nodes {
            XCTAssertNotNil(node["kind"] as? String)
            XCTAssertNotNil(node["tree"] as? String)
            if let parent = node["parent"] as? Int { XCTAssertNotNil(byID[parent], "parent \(parent) of \(node["id"]!)") }
        }

        let name = try XCTUnwrap(nodes.first { ($0["text"] as? [String: Any])?["string"] as? String == "Anna Petrova" })
        let font = try XCTUnwrap((name["text"] as? [String: Any])?["font"] as? [String: Any])
        XCTAssertEqual(font["size"] as? Double, 22)
        XCTAssertEqual(font["weight"] as? String, "Bold")
        XCTAssertEqual(font["textStyle"] as? String, "Title 2")
        XCTAssertEqual(name["component"] as? String, "ProfileHeader")

        // The same numbers as the capture API (QueryTests.test_profile) and the Spacing overlay.
        let header = try XCTUnwrap(snapshot.capture.find("ProfileHeader", kind: .component))
        let row = try XCTUnwrap(header.descendants(.stack).first { $0.stack?.axis == .horizontal })
        let rowJSON = try XCTUnwrap(byID[row.id]?["stack"] as? [String: Any])
        XCTAssertEqual(rowJSON["spacing"] as? Double, 14)
        XCTAssertEqual((rowJSON["gaps"] as? [Double])?.first, 14)
        // Children in screen order: avatar, then the name column.
        let columns = row.children.filter { !$0.frame.isNull }.sorted { $0.frame.minX < $1.frame.minX }
        let gaps = try XCTUnwrap(byID[columns[1].id]?["siblingGaps"] as? [String: Any])
        XCTAssertEqual(gaps["before"] as? Double, 14)

        let padding = try XCTUnwrap(snapshot.capture.nodes(.padding).first { $0.padding?.declared?.leading == 16 })
        let paddingJSON = try XCTUnwrap(byID[padding.id]?["padding"] as? [String: Any])
        XCTAssertEqual((paddingJSON["measured"] as? [String: Any])?["leading"] as? Double, 16)
        XCTAssertEqual((paddingJSON["declared"] as? [String: Any])?["leading"] as? Double, 16)

        // Frames in window points, the ones Measure draws between.
        let frame = try XCTUnwrap(name["frame"] as? [Double])
        XCTAssertEqual(frame.count, 4)
        let avatar = try XCTUnwrap(columns.first)
        let avatarFrame = try XCTUnwrap(byID[avatar.id]?["frame"] as? [Double])
        XCTAssertEqual(frame[0] - (avatarFrame[0] + avatarFrame[2]), 14, accuracy: 0.01, "avatar → name, as Measure shows")

        let lint = try XCTUnwrap(json["lint"] as? [[String: Any]])
        for issue in lint { XCTAssertNotNil(byID[issue["node"] as? Int ?? -1], "\(issue)") }

        // A fixture for `Tools/test_li.py`: the CLI must read the same numbers from these files.
        if let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            let dir = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/LayoutInspector/fixtures/profile")
            let files = try snapshot.write(to: dir, modes: [.spacing])
            XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["spacing.png", "report.txt", "capture.json", "status.json"])
        }
    }

    // MARK: - Helpers

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for: \(what)")
        throw CancellationError()
    }

    private static func json(_ url: URL) -> [String: Any]? {
        FileManager.default.contents(atPath: url.path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
