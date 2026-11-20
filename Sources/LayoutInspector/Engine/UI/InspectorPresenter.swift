#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
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
        // A whole-window session is never dead: it moves to another window by itself.
        let dead = sessions.filter { !$0.isAttached && !$0.followsFrontWindow }
        dead.forEach { $0.tearDown() }
        sessions.removeAll { session in dead.contains { $0 === session } }
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
        guard configuration.isEnabled, let target = Self.frontWindow() ?? Self.appWindow() else { return }
        let session = InspectorSession(configuration: configuration)
        session.attach(window: target)
        session.followsFrontWindow = true
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

    /// The window that takes a touch in the middle of the screen: the app's content, or a debug menu, sheet or popup
    /// the app shows in a window of its own. Passive overlays (floating buttons, banners) let that touch through.
    /// Windows without a root view controller are skipped: they are not content, and their `hitTest` may have side
    /// effects (activity trackers count every call as a touch).
    static func frontWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        let bounds = scene.coordinateSpace.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return scene.windows.enumerated()
            .filter { !($0.element is InspectorWindow) && !$0.element.isHidden && $0.element.rootViewController != nil }
            .filter { !isKeyboardWindow($0.element) }
            // `windows` is in the order windows were attached, not their z-order; the key one wins a tie.
            .sorted {
                ($0.element.windowLevel.rawValue, $0.element.isKeyWindow ? 1 : 0, $0.offset)
                    > ($1.element.windowLevel.rawValue, $1.element.isKeyWindow ? 1 : 0, $1.offset)
            }
            .map(\.element)
            .first { window in
                window.isUserInteractionEnabled
                    && window.hitTest(window.convert(center, from: scene.coordinateSpace), with: nil) != nil
            }
    }

    /// The keyboard's windows take touches in the middle of the screen in landscape.
    private static func isKeyboardWindow(_ window: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: window))
        return name.contains("Keyboard") || name == "UITextEffectsWindow"
    }

    static func appWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let windows = scene?.windows.filter { !($0 is InspectorWindow) && !$0.isHidden } ?? []
        // The app's own content is at `.normal`; alerts, overlays and debug tools (which may be key while the
        // inspector is turned on from them) live above it.
        let content = windows.filter { $0.windowLevel == .normal && $0.rootViewController != nil }
        return content.first(where: \.isKeyWindow) ?? content.first ?? windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

#endif
