import SwiftUI
import XCTest
@_spi(Diagnostics) import LayoutInspector
@testable import InspectorDemo

/// `.layoutInspector(…)`: attaching, runtime configuration, presentations.
@MainActor
final class InspectorModifierTests: XCTestCase {
    override func tearDown() async throws {
        LayoutInspector.isEnabled = true
        LayoutInspector.hide()
        try await super.tearDown()
    }

    /// The modifier's helper view must not show up in what is inspected.
    func test_modifier_doesNotChangeCapturedLayout() async throws {
        var options = LayoutReport.Options()
        options.includeRenderTree = true

        let plain = ScreenHarness(DemoScreen.profile.view)
        let expected = try await plain.waitUntilLoaded().report(options)
        plain.tearDown()

        let inspected = ScreenHarness(DemoScreen.profile.view.layoutInspector(.spacing))
        defer { inspected.tearDown() }
        let report = try await inspected.waitUntilLoaded().report(options)
        XCTAssertEqual(report, expected)
    }

    func test_isEnabled_togglesInspector_withoutResettingContent() async throws {
        let model = Model()
        let harness = ScreenHarness(ModelHost(model: model))
        defer { harness.tearDown() }

        try await waitUntil { LayoutInspector.activeWindow != nil }
        try await waitUntil { LayoutInspector.activeCapture?.find("Probe", kind: .text) != nil }

        model.configuration.isEnabled = false
        try await waitUntil { LayoutInspector.activeWindow == nil }

        model.configuration.isEnabled = true
        try await waitUntil { LayoutInspector.activeWindow != nil }

        XCTAssertEqual(Set(model.stateTokens).count, 1, "the inspected view was re-created")
    }

    func test_toolbarChanges_areWrittenBack() async throws {
        let model = Model()
        let harness = ScreenHarness(ModelHost(model: model))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeWindow != nil }

        LayoutInspector.activeConfiguration?.mode = .lint
        XCTAssertEqual(model.configuration.mode, .lint)

        LayoutInspector.activeConfiguration?.isEnabled = false   // the close button
        XCTAssertFalse(model.configuration.isEnabled)
        try await waitUntil { LayoutInspector.activeWindow == nil }
    }

    func test_bindingChanges_reachTheInspector() async throws {
        let model = Model()
        let harness = ScreenHarness(ModelHost(model: model))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeWindow != nil }

        model.configuration.mode = .typography
        model.configuration.toolbar = .hidden
        try await waitUntil { LayoutInspector.activeConfiguration?.mode == .typography }
        XCTAssertEqual(LayoutInspector.activeConfiguration?.toolbar, .hidden)
    }

    func test_constantConfiguration_closesLocally() async throws {
        let harness = ScreenHarness(Text("Probe").layoutInspector(.components))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeWindow != nil }

        LayoutInspector.activeConfiguration?.isEnabled = false
        try await waitUntil { LayoutInspector.activeWindow == nil }
    }

    func test_globalSwitch() async throws {
        let model = Model()
        let harness = ScreenHarness(ModelHost(model: model))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeWindow != nil }

        LayoutInspector.isEnabled = false
        try await waitUntil { LayoutInspector.activeWindow == nil }

        LayoutInspector.isEnabled = true
        try await waitUntil { LayoutInspector.activeWindow != nil }
        XCTAssertEqual(Set(model.stateTokens).count, 1, "the inspected view was re-created")
    }

    func test_disabledConfiguration_showsNothing() async throws {
        let harness = ScreenHarness(Text("Probe").layoutInspector(.components, isEnabled: false))
        defer { harness.tearDown() }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(LayoutInspector.activeWindow)
        XCTAssertNil(LayoutInspector.activeConfiguration)
    }

    /// In a sheet only the sheet's content is inspected, not the screen below.
    func test_sheet_inspectsOnlyPresentedContent() async throws {
        let model = Model()
        model.isPresenting = true
        let harness = ScreenHarness(Presenter(model: model, sheetConfiguration: .init(mode: .spacing)))
        defer { harness.tearDown() }

        try await waitUntil(timeout: .seconds(15)) {
            LayoutInspector.activeCapture?.find("ProfileHeader", kind: .component) != nil
        }
        XCTAssertNil(LayoutInspector.activeCapture?.find("Presenter", kind: .text))
        XCTAssertEqual(LayoutInspector.activeConfiguration?.mode, .spacing)
    }

    /// A sheet without an inspector hides the inspector of the screen below; dismissing it brings it back.
    func test_presentationAbove_hidesInspector() async throws {
        let model = Model()
        let harness = ScreenHarness(Presenter(model: model, sheetConfiguration: nil).layoutInspector(.components))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeWindow != nil }

        model.isPresenting = true
        try await waitUntil { LayoutInspector.activeWindow == nil }

        model.isPresenting = false
        try await waitUntil { LayoutInspector.activeWindow != nil }
    }

    /// A sheet with its own inspector takes over and hands back when dismissed.
    func test_nestedInspectors_handOver() async throws {
        let model = Model()
        let harness = ScreenHarness(Presenter(model: model, sheetConfiguration: .init(mode: .lint)).layoutInspector(.components))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeConfiguration?.mode == .components }

        model.isPresenting = true
        try await waitUntil { LayoutInspector.activeConfiguration?.mode == .lint && LayoutInspector.activeWindow != nil }

        model.isPresenting = false
        try await waitUntil { LayoutInspector.activeConfiguration?.mode == .components && LayoutInspector.activeWindow != nil }
    }

    /// The drawn overlay moves with the screen during a push and is kept for when the screen comes back.
    func test_overlayFollowsNavigationTransition() async throws {
        let model = Model()
        let harness = ScreenHarness(PushingScreen(model: model))
        defer { harness.tearDown() }
        try await waitUntil { LayoutInspector.activeCapture?.find("Probe", kind: .text) != nil }
        let overlay = try XCTUnwrap(LayoutInspector.activeWindow?.rootViewController?.view.subviews.first)
        XCTAssertEqual(overlay.transform, .identity)

        model.isPresenting = true
        // UIKit puts the screen at its final place at once and animates the presentation layer:
        // the overlay compensates with a translation that fades out as the animation ends.
        var largestShift: CGFloat = 0
        while LayoutInspector.activeWindow != nil {
            largestShift = max(largestShift, abs(overlay.transform.tx))
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(largestShift, 20, "the overlay did not move with the screen")

        model.isPresenting = false
        try await waitUntil { LayoutInspector.activeWindow != nil }
        XCTAssertNotNil(LayoutInspector.activeCapture?.find("Probe", kind: .text), "capture was dropped")
        try await waitUntil { overlay.transform == .identity }
    }

    /// The inspector's window is above the keyboard: the toolbar must move up with it.
    func test_toolbarStaysAboveKeyboard() async throws {
        let harness = ScreenHarness(FocusedField().layoutInspector(.components))
        defer { harness.tearDown() }
        harness.window.makeKey()
        try await waitUntil { LayoutInspector.activeWindow != nil }
        let root = try XCTUnwrap(LayoutInspector.activeWindow?.rootViewController?.view)
        let panel = try XCTUnwrap(root.subviews.last)
        let bottomWithoutKeyboard = panel.frame.maxY

        let keyboardShown = expectation(forNotification: UIResponder.keyboardDidShowNotification, object: nil)
        harness.window.endEditing(false)
        NotificationCenter.default.post(name: .focusProbeField, object: nil)
        guard await XCTWaiter().fulfillment(of: [keyboardShown], timeout: 3) == .completed else {
            throw XCTSkip("No software keyboard (the simulator uses the hardware keyboard)")
        }
        try await waitUntil { panel.frame.maxY < bottomWithoutKeyboard - 100 }
    }

    func test_windowInspector() async throws {
        let harness = ScreenHarness(Text("Probe"))
        defer { harness.tearDown() }
        harness.window.makeKey()

        LayoutInspector.show(.init(mode: .typography))
        XCTAssertTrue(LayoutInspector.isVisible)
        try await waitUntil { LayoutInspector.activeCapture?.find("Probe", kind: .text) != nil }

        LayoutInspector.hide()
        XCTAssertFalse(LayoutInspector.isVisible)
        XCTAssertNil(LayoutInspector.activeWindow)
    }

    // MARK: -

    private func waitUntil(timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met in \(timeout)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class Model: ObservableObject {
    @Published var configuration = LayoutInspector.Configuration()
    @Published var isPresenting = false
    var stateTokens: [UUID] = []
}

private struct ModelHost: View {
    @ObservedObject var model: Model

    var body: some View {
        Probe(model: model).layoutInspector($model.configuration)
    }
}

/// Reports its `@State` on appear: a new token means the view lost its state.
private struct Probe: View {
    let model: Model
    @State private var token = UUID()

    var body: some View {
        Text("Probe").padding(24).onAppear { model.stateTokens.append(token) }
    }
}

private struct PushingScreen: View {
    @ObservedObject var model: Model

    var body: some View {
        Text("Probe")
            .padding(80)
            .layoutInspector(.components)
            .navigationDestination(isPresented: $model.isPresenting) { Text("Pushed") }
    }
}

extension Notification.Name {
    static let focusProbeField = Notification.Name("focusProbeField")
}

private struct FocusedField: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .focused($focused)
            .padding(40)
            .onReceive(NotificationCenter.default.publisher(for: .focusProbeField)) { _ in focused = true }
    }
}

private struct Presenter: View {
    @ObservedObject var model: Model
    let sheetConfiguration: LayoutInspector.Configuration?

    var body: some View {
        Text("Presenter")
            .sheet(isPresented: $model.isPresenting) {
                if let sheetConfiguration {
                    NavigationStack { ProfileScreen() }.layoutInspector(sheetConfiguration)
                } else {
                    Text("Plain sheet")
                }
            }
    }
}
