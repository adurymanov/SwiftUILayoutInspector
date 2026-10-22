#if LayoutInspectorEngine && os(iOS)
import UIKit

/// Decides which inspector is on screen. One at a time: the most recently attached one.
/// A screen with an inspector that presents another screen with an inspector hands over to it and
/// takes over again when it is dismissed.
final class InspectorPresenter {
    static let shared = InspectorPresenter()

    /// Attached sessions in activation order; the last one is on screen.
    private(set) var sessions: [InspectorSession] = []
    private var windowSession: InspectorSession?

    var frontmost: InspectorSession? { sessions.last }

    func activate(_ session: InspectorSession) {
        sessions.removeAll { $0 === session }
        sessions.append(session)
        update()
    }

    func deactivate(_ session: InspectorSession) {
        sessions.removeAll { $0 === session }
        session.setFrontmost(false)
        update()
    }

    private func update() {
        for session in sessions.dropLast() { session.setFrontmost(false) }
        sessions.last?.setFrontmost(true)
    }

    // MARK: - Whole window

    var isWindowInspectorVisible: Bool { windowSession != nil }

    func showWindowInspector(_ configuration: LayoutInspector.Configuration) {
        if let windowSession {
            windowSession.apply(configuration)
            return
        }
        guard configuration.isEnabled, let target = Self.appWindow() else { return }
        let session = InspectorSession(configuration: configuration)
        session.attach(window: target)
        session.onConfigurationChange = { [weak self] configuration in
            if !configuration.isEnabled { self?.hideWindowInspector() }
        }
        windowSession = session
        activate(session)
    }

    func hideWindowInspector() {
        guard let session = windowSession else { return }
        windowSession = nil
        deactivate(session)
        session.tearDown()
    }

    static func appWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let windows = scene?.windows.filter { !($0 is InspectorWindow) && !$0.isHidden } ?? []
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

#endif
