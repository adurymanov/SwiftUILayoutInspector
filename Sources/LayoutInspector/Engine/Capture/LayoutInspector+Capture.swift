#if LayoutInspectorEngine && os(iOS)
import UIKit

extension LayoutInspector {
    /// Captures the layout of `view` (usually a window) as it is now. Node frames are in `view`'s coordinates.
    ///
    /// ```swift
    /// let layout = LayoutInspector.capture(window)
    /// XCTAssertEqual(layout.find("Title", kind: .text)?.font?.size, 22)
    /// ```
    public static func capture(_ view: UIView) -> InspectorCapture {
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
            view.layoutIfNeeded()
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
