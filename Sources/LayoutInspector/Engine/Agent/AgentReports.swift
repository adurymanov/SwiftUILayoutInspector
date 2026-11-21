#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// Report files for agents and scripts on the Mac, written after every capture of the inspector on screen:
///
/// - `report.txt` – the text the toolbar's "Share report" gives;
/// - `capture.json` – every node with its facts (schema in `Docs/Agents.md`, `schemaVersion`);
/// - `status.json` – mode, capture number, time, duration, versions, the last command; written last, so when it
///   names a capture the other two files already hold it.
///
/// Each file is replaced atomically (written next to it, then renamed) on a background queue.
///
/// Where: `LAYOUT_INSPECTOR_DUMP` if set; in the simulator a directory the Mac reads directly,
/// `$SIMULATOR_HOST_HOME/Library/Caches/LayoutInspector/<SIMULATOR_UDID>/<bundle id>/`; otherwise, or when that is not
/// writable, `Library/Caches/LayoutInspector/` of the app.
///
/// When: once the app got a command from the Mac (`AgentControl`), in Xcode previews, or with
/// `LAYOUT_INSPECTOR_REPORTS=1`. An app that is only looked at by a human writes nothing.
enum AgentReports {
    static let launchID = UUID().uuidString

    /// Previews and the environment switches keep the files on for the whole process; commands only until `close`.
    static let writesByEnvironment: Bool = {
        let env = ProcessInfo.processInfo.environment
        if let value = env["LAYOUT_INSPECTOR_REPORTS"] { return value != "0" }
        return env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" || env["LAYOUT_INSPECTOR_DUMP"].map { !$0.isEmpty } == true
    }()

    static var isWriting: Bool = writesByEnvironment

    /// Captures finished by the inspector on screen in this process.
    private(set) static var captureCount = 0
    private static var lastCapture: [String: Any]?
    private static let queue = DispatchQueue(label: "dev.layoutinspector.reports", qos: .utility)

    static var directory: URL? { resolvedDirectory.url }
    private static let resolvedDirectory: (url: URL?, isFallback: Bool) = resolveDirectory()

    // MARK: - Events

    /// A session finished a capture. `afterCommand` – the number of the last command when the capture started.
    static func didFinish(_ capture: InspectorCapture, session: InspectorSession, afterCommand: Int) {
        captureCount += 1
        guard isWriting, let dir = directory else { return }
        let start = CACurrentMediaTime()
        let bounds = session.overlay.space?.bounds ?? .infinite
        let report = session.reportText ?? ""
        var json = CaptureJSON.object(for: capture, rules: session.configuration.lintRules, bounds: bounds, space: session.overlay.space,
                                     renderCounts: session.renderCounts)
        let mainMs = (CACurrentMediaTime() - start) * 1000
        let info: [String: Any] = [
            "number": captureCount,
            "afterCommand": afterCommand,
            "date": capture.date.timeIntervalSince1970,
            "duration": capture.duration,
            "mode": session.configuration.mode.rawValue,
            "graph": capture.isSwiftUIGraphAvailable,
            "nodes": capture.swiftUINodes.count,
            "timings": LayoutCapture.lastTimings,
            "writeMainThreadMs": (mainMs * 10).rounded() / 10,
        ]
        json["capture"] = info
        lastCapture = info
        let status = statusObject()
        let box = UncheckedBox((json, status))
        queue.async {
            let (json, status) = box.value
            write(json: json, to: dir.appendingPathComponent("capture.json"))
            write(Data(report.utf8), to: dir.appendingPathComponent("report.txt"))
            write(json: status, to: dir.appendingPathComponent("status.json"))
        }
    }

    static func commandReceived() {
        guard isWriting, let dir = directory else { return }
        let box = UncheckedBox(statusObject())
        queue.async {
            write(json: box.value, to: dir.appendingPathComponent("status.json"))
        }
    }

    /// Waits until everything queued so far is on disk. Tests.
    static func flush() { queue.sync {} }

    // MARK: - Status

    static func statusObject() -> [String: Any] {
        var status: [String: Any] = [
            "schemaVersion": CaptureJSON.schemaVersion,
            "library": LayoutInspector.version,
            "updated": Date().timeIntervalSince1970,
            "app": [
                "bundleID": Bundle.main.bundleIdentifier ?? "",
                "process": ProcessInfo.processInfo.processName,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "launchID": launchID,
            ] as [String: Any],
            "enabled": LayoutInspector.isEnabled,
            "graph": LayoutInspector.isSwiftUIGraphRecordingEnabled,
            "directoryIsFallback": resolvedDirectory.isFallback,
        ]
        let presenter = InspectorPresenter.shared
        if let session = presenter.frontmost, session.configuration.isEnabled {
            status["inspector"] = [
                "kind": session === presenter.windowSessionIfAny ? "window" : "view",
                "highlighting": session.isHighlighting,
                "mode": session.configuration.mode.rawValue,
                "capturing": session.captureProgress != nil,
            ] as [String: Any]
        } else {
            status["inspector"] = ["kind": "none"]
        }
        if let lastCommand = AgentControl.lastCommand {
            status["command"] = [
                "name": lastCommand.name,
                "number": lastCommand.number,
                "date": lastCommand.date.timeIntervalSince1970,
            ] as [String: Any]
        }
        if let lastCapture { status["capture"] = lastCapture }
        return status
    }

    // MARK: - Files

    nonisolated static func write(json: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        write(data, to: url)
    }

    /// Writes next to `url`, then renames over it: a reader never sees half a file.
    nonisolated static func write(_ data: Data, to url: URL) {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if rename(temp.path, url.path) != 0 { try? FileManager.default.removeItem(at: temp) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static func resolveDirectory() -> (url: URL?, isFallback: Bool) {
        let env = ProcessInfo.processInfo.environment
        if let dump = env["LAYOUT_INSPECTOR_DUMP"], !dump.isEmpty {
            let url = URL(fileURLWithPath: dump, isDirectory: true)
            if isWritable(url) { return (url, false) }
        }
        if let home = env["SIMULATOR_HOST_HOME"], let udid = env["SIMULATOR_UDID"] {
            let url = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Caches/LayoutInspector", isDirectory: true)
                .appendingPathComponent(udid, isDirectory: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
            if isWritable(url) { return (url, false) }
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let url = caches?.appendingPathComponent("LayoutInspector", isDirectory: true), isWritable(url) {
            return (url, true)
        }
        return (nil, true)
    }

    private static func isWritable(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".probe-\(launchID)")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}

/// Moves values built on the main thread to the writer queue; nothing touches them on the main thread afterwards.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

#endif
