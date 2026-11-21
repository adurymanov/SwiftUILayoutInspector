#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// Commands from the Mac: one Darwin notification per command, so a script drives the inspector of an app running in
/// the simulator without taps:
///
///     xcrun simctl spawn <udid> notifyutil -p dev.layoutinspector.mode.spacing
///
/// The app listens to `dev.layoutinspector.<command>` and to `dev.layoutinspector.<bundle id>.<command>`, so a command
/// can reach every app on the simulator or just one. After a command the inspector writes its report files (see
/// `AgentReports`) after every capture.
enum AgentControl {
    static let prefix = "dev.layoutinspector."

    enum Command: Equatable {
        /// Highlight the screen in this mode, capturing it again. Shows the inspector if it was closed.
        case mode(LayoutInspector.Mode)
        /// Stop highlighting; the button stays.
        case off
        /// Capture again in the current mode.
        case refresh
        /// Close the inspector, like its Close button.
        case close
        /// Only write `status.json`.
        case status

        init?(name: String) {
            switch name {
            case "off": self = .off
            case "refresh": self = .refresh
            case "close": self = .close
            case "status": self = .status
            default:
                guard name.hasPrefix("mode."), let mode = LayoutInspector.Mode(rawValue: String(name.dropFirst(5))) else {
                    return nil
                }
                self = .mode(mode)
            }
        }

        var name: String {
            switch self {
            case .mode(let mode): "mode.\(mode.rawValue)"
            case .off: "off"
            case .refresh: "refresh"
            case .close: "close"
            case .status: "status"
            }
        }

        static let all: [Command] = LayoutInspector.Mode.allCases.map(Command.mode) + [.off, .refresh, .close, .status]
    }

    private(set) static var isListening = false
    /// Commands received in this process. A capture that starts after command N is tagged with N.
    private(set) static var commandCount = 0
    private(set) static var lastCommand: (name: String, number: Int, date: Date)?
    /// Called for every command after it is performed; tests use it.
    static var onCommand: ((Command) -> Void)?

    /// Notification names the app listens to: the global one and the one scoped to this app.
    static func notificationNames(for command: Command, bundleID: String? = Bundle.main.bundleIdentifier) -> [String] {
        var names = [prefix + command.name]
        if let bundleID, !bundleID.isEmpty { names.append(prefix + bundleID + "." + command.name) }
        return names
    }

    static func startListening() {
        guard !isListening else { return }
        isListening = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in Command.all {
            for name in notificationNames(for: command) {
                CFNotificationCenterAddObserver(center, nil, agentNotificationCallback, name as CFString, nil, .deliverImmediately)
            }
        }
    }

    /// `name` – the full notification name.
    static func receive(_ name: String) {
        guard name.hasPrefix(prefix) else { return }
        let rest = String(name.dropFirst(prefix.count))
        let commandName: String
        if let bundleID = Bundle.main.bundleIdentifier, rest.hasPrefix(bundleID + ".") {
            commandName = String(rest.dropFirst(bundleID.count + 1))
        } else {
            commandName = rest
        }
        guard let command = Command(name: commandName) else { return }
        perform(command)
    }

    static func perform(_ command: Command) {
        commandCount += 1
        lastCommand = (command.name, commandCount, Date())
        AgentReports.isWriting = true
        if LayoutInspector.isEnabled {
            let presenter = InspectorPresenter.shared
            let session = presenter.frontmost.flatMap { $0.configuration.isEnabled ? $0 : nil }
            switch command {
            case .mode(let mode):
                if let session {
                    session.agentHighlight(mode)
                } else {
                    var configuration = presenter.lastWindowConfiguration ?? LayoutInspector.Configuration()
                    configuration.isEnabled = true
                    configuration.mode = mode
                    configuration.highlightsOnAppear = true
                    presenter.showWindowInspector(configuration)
                }
            case .off:
                session?.stopHighlighting()
            case .refresh:
                session?.agentHighlight(session?.configuration.mode ?? .components)
            case .close:
                if let session {
                    if session === presenter.windowSessionIfAny {
                        presenter.hideWindowInspector()
                    } else {
                        session.configuration.isEnabled = false
                    }
                }
            case .status:
                break
            }
        }
        AgentReports.commandReceived()
        if case .close = command, !AgentReports.writesByEnvironment {
            // Every automatic re-capture would otherwise keep building the report on the main thread.
            AgentReports.isWriting = false
        }
        onCommand?(command)
    }
}

nonisolated private func agentNotificationCallback(
    _ center: CFNotificationCenter?, _ observer: UnsafeMutableRawPointer?, _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?, _ userInfo: CFDictionary?
) {
    guard let name = name?.rawValue as String? else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { AgentControl.receive(name) }
    }
}

#endif

#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
extension LayoutInspector {
    /// Where the report files for agents go (see `Docs/Agents.md`); `nil` if no directory is writable.
    @_spi(Diagnostics) public static var reportDirectory: URL? { AgentReports.directory }

    /// Waits until the report files queued so far are written.
    @_spi(Diagnostics) public static func flushReports() { AgentReports.flush() }

    /// Writes `data` next to `url`, then renames it over `url`.
    @_spi(Diagnostics) public static func writeAtomically(_ data: Data, to url: URL) { AgentReports.write(data, to: url) }

    /// Commands from the Mac received in this process.
    @_spi(Diagnostics) public static var agentCommandCount: Int { AgentControl.commandCount }
}
#endif
