import XCTest
import LayoutInspector

/// SwiftUI reads `SWIFTUI_VIEW_DEBUG` once per process, when it creates its first view graph.
/// The test host has long shown its SwiftUI window, so any `bootstrap()` here is a late one.
@MainActor
final class BootstrapTests: XCTestCase {
    private var savedValue: String?

    override func setUp() async throws {
        try await super.setUp()
        savedValue = getenv("SWIFTUI_VIEW_DEBUG").map { String(cString: $0) }
    }

    override func tearDown() async throws {
        if let savedValue { setenv("SWIFTUI_VIEW_DEBUG", savedValue, 1) } else { unsetenv("SWIFTUI_VIEW_DEBUG") }
        LayoutInspector.isEnabled = true
        try await super.tearDown()
    }

    func test_lateBootstrap_doesNotPretendToRecord() {
        unsetenv("SWIFTUI_VIEW_DEBUG")
        LayoutInspector.bootstrap()
        XCTAssertNil(getenv("SWIFTUI_VIEW_DEBUG"))
        XCTAssertFalse(LayoutInspector.isSwiftUIGraphRecordingEnabled)
        XCTAssertTrue(LayoutInspector.isEnabled)
    }

    /// The variable set before launch (scheme, or the host app's own `bootstrap()`) is what counts.
    func test_variableSetBeforeLaunch_keepsRecording() {
        XCTAssertNotNil(savedValue)
        LayoutInspector.bootstrap()
        XCTAssertTrue(LayoutInspector.isSwiftUIGraphRecordingEnabled)
    }

    func test_disabledBootstrap_turnsInspectorsOff() {
        LayoutInspector.bootstrap(isEnabled: false)
        XCTAssertFalse(LayoutInspector.isEnabled)
    }
}
