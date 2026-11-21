import XCTest
@testable import LayoutInspector

/// `LayoutInspector.version` is what `li` and the report files say about the app. 0.2.9 shipped saying 0.2.8:
/// the constant, the top of the CHANGELOG and `li` must move together.
final class VersionTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func test_versionMatchesChangelogAndCLI() throws {
        let changelog = try String(contentsOf: repository.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let top = changelog.split(separator: "\n").first { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
        XCTAssertEqual(LayoutInspector.version, top, "LayoutInspector.version differs from the top entry of CHANGELOG.md")

        let cli = try String(contentsOf: repository.appendingPathComponent("Tools/li"), encoding: .utf8)
        let line = cli.split(separator: "\n").first { $0.hasPrefix("LI_VERSION = ") }
        XCTAssertEqual(line, "LI_VERSION = \"\(LayoutInspector.version)\"", "Tools/li has another version")
    }
}
