#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit

extension LayoutInspector {
    /// A view captured on its own, without an app around it: for scripts, tests and Xcode's `RunCodeSnippet`.
    ///
    /// ```swift
    /// let snapshot = await LayoutInspector.snapshot(ProfileScreen())
    /// print(snapshot.report)
    /// try snapshot.write(to: URL(fileURLWithPath: "/tmp/profile"), modes: [.spacing])
    /// ```
    public struct Snapshot {
        /// The capture; node frames are in window points.
        public let capture: InspectorCapture
        /// The window the view was laid out in. It stays on screen until ``close()``.
        public let window: UIWindow
        /// `false` when the view did not settle within the timeout (a shimmer, a timer): the capture is of the
        /// moment the time ran out.
        public let isStable: Bool
        /// How long it took to settle, in seconds.
        public let settleTime: TimeInterval

        /// The text report, the same as the toolbar's "Share report".
        public var report: String { capture.report() }

        /// `capture.json`: every node with its facts and the lint issues (schema: `Docs/Agents.md`). Accessibility ids
        /// and labels are there for UIKit views only.
        public func json(rules: LintRules = LintRules()) -> Data {
            var object = CaptureJSON.object(for: capture, rules: rules, bounds: window.bounds, space: window)
            object["capture"] = [
                "number": 1,
                "afterCommand": 0,
                "date": capture.date.timeIntervalSince1970,
                "duration": capture.duration,
                "graph": capture.isSwiftUIGraphAvailable,
                "nodes": capture.swiftUINodes.count,
                "stable": isStable,
                "settleTime": settleTime,
            ] as [String: Any]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }

        /// The view with the overlay of `mode`.
        public func image(_ mode: Mode, scale: CGFloat = 2) -> UIImage {
            InspectorImageRenderer.image(of: window, capture: capture, options: InspectorRenderOptions(mode: mode), scale: scale)
        }

        /// Writes `report.txt`, `capture.json`, `status.json` and a `<mode>.png` per mode into `directory`, each file
        /// replaced atomically. Returns the files written.
        @discardableResult
        public func write(to directory: URL, modes: [Mode] = [], rules: LintRules = LintRules()) throws -> [URL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var files: [URL] = []
            func put(_ data: Data, _ name: String) {
                let url = directory.appendingPathComponent(name)
                AgentReports.write(data, to: url)
                files.append(url)
            }
            for mode in modes {
                if let png = image(mode).pngData() { put(png, "\(mode.rawValue).png") }
            }
            put(Data(report.utf8), "report.txt")
            put(json(rules: rules), "capture.json")
            let status: [String: Any] = [
                "schemaVersion": CaptureJSON.schemaVersion,
                "library": LayoutInspector.version,
                "updated": Date().timeIntervalSince1970,
                "graph": LayoutInspector.isSwiftUIGraphRecordingEnabled,
                "capture": ["number": 1, "afterCommand": 0, "date": capture.date.timeIntervalSince1970,
                            "duration": capture.duration, "stable": isStable, "settleTime": settleTime,
                            "nodes": capture.swiftUINodes.count] as [String: Any],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) { put(data, "status.json") }
            return files
        }

        /// Hides the window and releases the view.
        public func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// Lays `content` out in a window of its own, waits until it settles (see
    /// ``captureWhenStable(_:timeout:quietPeriod:until:)``) and captures it.
    ///
    /// The window joins the app's scene when there is one, so it gets a safe area and is drawn like the app; the Xcode
    /// preview agent has one. Without a scene it is laid out and drawn off screen.
    ///
    /// - Parameters:
    ///   - size: window size in points; `nil` – the screen.
    ///   - fitsHeight: the window takes the content's own height at `size.width`, for components
    ///     (`#Preview(traits: .sizeThatFitsLayout)`).
    ///   - timeout: how long to wait for the content to settle; the capture is taken anyway when the time runs out.
    public static func snapshot<Content: View>(
        _ content: Content,
        size: CGSize? = nil,
        fitsHeight: Bool = false,
        timeout: Duration = .seconds(15)
    ) async -> Snapshot {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        let bounds = size.map { CGRect(origin: .zero, size: $0) } ?? scene?.screen.bounds ?? UIScreen.main.bounds
        window.frame = bounds
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        if fitsHeight {
            let fitting = host.sizeThatFits(in: CGSize(width: bounds.width, height: 10_000))
            window.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(1, fitting.height.rounded(.up)))
        }
        window.isHidden = false
        window.layoutIfNeeded()
        let clock = ContinuousClock()
        let start = clock.now
        var capture: InspectorCapture
        var isStable = true
        do {
            capture = try await captureWhenStable(window, timeout: timeout)
        } catch {
            isStable = false
            capture = self.capture(window)
        }
        let elapsed = clock.now - start
        let settle = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Snapshot(capture: capture, window: window, isStable: isStable, settleTime: settle)
    }
}

#endif
