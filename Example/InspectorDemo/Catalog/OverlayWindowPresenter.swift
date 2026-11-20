import SwiftUI
import LayoutInspector

/// Shows a screen in a window of its own far above `.alert`, the way apps host debug menus and their tools.
/// The inspector has to stay above it.
enum OverlayWindowPresenter {
    static let level = UIWindow.Level.alert + 99

    private static var window: UIWindow?

    static func present(_ screen: DemoScreen, inspector: LayoutInspector.Configuration) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = level
        window.rootViewController = UIHostingController(
            rootView: NavigationStack {
                screen.view.toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .layoutInspector(inspector)
        )
        window.makeKeyAndVisible()
        self.window = window
    }

    static func dismiss() {
        window?.isHidden = true
        window = nil
    }
}
