#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

extension LayoutInspector {
    /// Captures the layout of `view` (usually a window) as it is now. Node frames are in `view`'s coordinates.
    ///
    /// ```swift
    /// let layout = LayoutInspector.capture(window)
    /// XCTAssertEqual(layout.find("Title", kind: .text)?.font?.size, 22)
    /// ```
    public static func capture(_ view: UIView) -> InspectorCapture {
        flushSwiftUIRendering(in: view)
        let capture = LayoutCapture.capture(view)
        capture.resolveFrames(in: view)
        return capture
    }

    /// Waits until the content of `view` settles and captures it: nothing moves for `quietPeriod`
    /// and `until` accepts the capture (by default: no visible `ProgressView`).
    ///
    /// Use it in tests and scripts for screens that load data asynchronously.
    /// - Throws: ``CaptureTimeoutError`` if the content does not settle within `timeout`.
    public static func captureWhenStable(
        _ view: UIView,
        timeout: Duration = .seconds(10),
        quietPeriod: Duration = .milliseconds(400),
        until isReady: @MainActor (InspectorCapture) -> Bool = { !$0.containsLoadingIndicator }
    ) async throws -> InspectorCapture {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastSignature = 0
        var stableSince = clock.now
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            flushSwiftUIRendering(in: view)
            let signature = LayoutCapture.layoutSignature(of: view)
            if signature != lastSignature {
                lastSignature = signature
                stableSince = clock.now
                continue
            }
            if clock.now - stableSince >= quietPeriod {
                let capture = capture(view)
                if isReady(capture) { return capture }
                stableSince = clock.now
            }
        }
        throw CaptureTimeoutError(timeout: timeout, lastReport: capture(view).report())
    }

    /// Brings the layers of a window without a scene up to date. SwiftUI redraws such a window only when a
    /// hosting view lays out, so whatever changed after the first layout (loaded data, inserted rows, finished
    /// animations) is in the view graph but not yet in the layers. Windows in a scene are left alone.
    static func flushSwiftUIRendering(in view: UIView) {
        guard ((view as? UIWindow) ?? view.window)?.windowScene == nil else {
            view.layoutIfNeeded()
            return
        }
        setNeedsLayoutRecursively(view)
        view.layoutIfNeeded()
    }

    private static func setNeedsLayoutRecursively(_ view: UIView) {
        view.setNeedsLayout()
        view.subviews.forEach(setNeedsLayoutRecursively)
    }

    /// The content did not settle in time.
    nonisolated public struct CaptureTimeoutError: Error, CustomStringConvertible {
        public let timeout: Duration
        /// ``LayoutReport`` of what was on screen when the time ran out.
        public let lastReport: String

        public var description: String { "Layout did not settle within \(timeout)" }
    }

    // MARK: - Diagnostics

    /// Where the time of the last capture went.
    @_spi(Diagnostics) public static var lastCaptureTimings: [String] { LayoutCapture.lastTimings }

    /// Everything `capture` holds as text, without ids and addresses: diff two of them to check a change.
    @_spi(Diagnostics) public static func dump(_ capture: InspectorCapture) -> String { CaptureDump.text(for: capture) }

    /// The `_ViewDebug` tree of a hosting view as the capture reads it: one line per node with its type, readable
    /// type, position, size and SwiftUI's encoding of its value. `nil` for other views.
    @_spi(Diagnostics) public static func debugDataDump(of host: UIView) -> String? { ViewDebugReader.dump(of: host) }

    /// One line of ``debugDataDump(of:)``, for comparing it with SwiftUI's JSON.
    @_spi(Diagnostics) public static func debugDataDumpLine(depth: Int, type: String, readable: String, origin: CGPoint?,
                                                           size: CGSize?, value: [String: Any]?) -> String {
        ViewDebugReader.dumpLine(depth: depth, type: type, readable: readable, origin: origin, size: size, value: value)
    }

    /// Each lookup the capture makes on a part of a node's value against the same lookup on the whole value, for
    /// every node of a hosting view: the differences, one per line; `nil` for other views.
    @_spi(Diagnostics) public static func partLookupMismatches(of host: UIView) -> [String]? {
        SwiftUITreeBuilder.partLookupMismatches(of: host)
    }

    /// Captures `view` the way the inspector on screen does: a few steps per frame within `budget` seconds.
    @_spi(Diagnostics) public static func captureInSlices(_ view: UIView, budget: TimeInterval = 0.012) async -> InspectorCapture {
        flushSwiftUIRendering(in: view)
        let job = LayoutCapture.Job(root: view, excluding: [])
        while !job.step(budget: budget) {
            try? await Task.sleep(for: .milliseconds(16))
        }
        let capture = job.result!
        capture.resolveFrames(in: view)
        return capture
    }

    /// Forgets the trees kept from earlier captures: the next capture reads every hosting view again.
    @_spi(Diagnostics) public static func resetCaptureCache() { LayoutCapture.resetCache() }

    /// How app-defined views were matched during the last capture.
    @_spi(Diagnostics) public static var lastReconstructionLog: [String] { LayoutCapture.lastReconstructionLog }

    /// Configuration of the inspector on screen. Setting it behaves like a change made from its toolbar
    /// (it is written back to the modifier's binding).
    @_spi(Diagnostics) public static var activeConfiguration: Configuration? {
        get { InspectorPresenter.shared.frontmost?.configuration }
        set { if let newValue { InspectorPresenter.shared.frontmost?.configuration = newValue } }
    }

    /// Latest capture of the inspector on screen.
    @_spi(Diagnostics) public static var activeCapture: InspectorCapture? { InspectorPresenter.shared.frontmost?.capture }

    /// Window of the inspector on screen, if it is visible.
    @_spi(Diagnostics) public static var activeWindow: UIWindow? {
        InspectorPresenter.shared.frontmost?.window.flatMap { $0.isHidden ? nil : $0 }
    }

    /// Captures now and selects the first node matching `query` in the inspector on screen
    /// (see ``InspectorCapture/find(_:kind:)``). Returns `false` if there is no such node.
    @_spi(Diagnostics) @discardableResult
    public static func select(_ query: String, kind: NodeKind? = nil) -> Bool {
        guard let session = InspectorPresenter.shared.frontmost else { return false }
        session.refresh()
        guard let node = session.capture?.find(query, kind: kind) else { return false }
        session.select(node)
        return true
    }
}

#endif
