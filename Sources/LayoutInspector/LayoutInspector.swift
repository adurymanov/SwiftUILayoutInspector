import Foundation
import Observation

/// Shows how SwiftUI laid out a view: component bounds, paddings and gaps, fonts, frame constraints,
/// Auto Layout of embedded UIKit views, design-rule violations and distances.
///
/// ```swift
/// @main struct MyApp: App {
///     init() {
///         LayoutInspector.bootstrap()        // before the first SwiftUI view is created
///     }
/// }
///
/// SomeScreen()
///     .layoutInspector(.spacing)            // or .layoutInspector($configuration)
/// ```
///
/// The inspected view is not changed: the overlay and the toolbar live in a separate window above the app,
/// and the data comes from the SwiftUI runtime. Everything happens on the main thread.
public enum LayoutInspector {
    /// Turns the inspector on for this process. Call it once, before the first SwiftUI view is created
    /// (`App.init` or `application(_:willFinishLaunchingWithOptions:)`).
    ///
    /// It asks SwiftUI to record its debug view graph (the same data Xcode's view debugger reads).
    /// Without it the inspector still works but only sees the UIKit render tree. Setting
    /// `SWIFTUI_VIEW_DEBUG=27` in the scheme has the same effect.
    ///
    /// - Parameter isEnabled: `false` keeps SwiftUI untouched and turns every inspector off
    ///   (see ``isEnabled``), e.g. `bootstrap(isEnabled: settings.isDebugMenuEnabled)`.
    public static func bootstrap(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        #if LayoutInspectorEngine && os(iOS)
        if isEnabled, getenv(debugEnvironmentKey) == nil {
            setenv(debugEnvironmentKey, String(debugProperties), 1)
        }
        #endif
    }

    /// Master switch for every inspector in the app. `false` removes all overlays and toolbars; modifiers
    /// become inert until it is turned back on. Defaults to `true`.
    public static var isEnabled: Bool {
        get { GlobalState.shared.isEnabled }
        set {
            GlobalState.shared.isEnabled = newValue
            #if LayoutInspectorEngine && os(iOS)
            if !newValue { InspectorPresenter.shared.hideWindowInspector() }
            #endif
        }
    }

    /// `false` when the inspector is compiled out (the `LayoutInspectorEngine` package trait is disabled)
    /// or the platform is not supported. Every API is then a no-op.
    public static var isAvailable: Bool {
        #if LayoutInspectorEngine && os(iOS)
        true
        #else
        false
        #endif
    }

    /// Whether SwiftUI records its debug view graph in this process (see ``bootstrap(isEnabled:)``).
    public static var isSwiftUIGraphRecordingEnabled: Bool {
        isAvailable && getenv(debugEnvironmentKey) != nil
    }

    /// Inspects the whole key window, without changing any view. Use it from a debug menu or a gesture.
    /// To inspect a particular screen, attach `.layoutInspector(_:)` to it instead.
    public static func show(_ configuration: Configuration = Configuration()) {
        #if LayoutInspectorEngine && os(iOS)
        guard isEnabled else { return }
        InspectorPresenter.shared.showWindowInspector(configuration)
        #endif
    }

    /// Hides the inspector shown with ``show(_:)``.
    public static func hide() {
        #if LayoutInspectorEngine && os(iOS)
        InspectorPresenter.shared.hideWindowInspector()
        #endif
    }

    /// Whether the inspector shown with ``show(_:)`` is on screen.
    public static var isVisible: Bool {
        #if LayoutInspectorEngine && os(iOS)
        InspectorPresenter.shared.isWindowInspectorVisible
        #else
        false
        #endif
    }

    static let debugEnvironmentKey = "SWIFTUI_VIEW_DEBUG"

    /// `_ViewDebug.Property` bits: type | value | position | size.
    /// `transform` is left out on purpose: it contains scroll geometry with infinite sizes, which makes
    /// SwiftUI's own JSON serialisation fail for screens with `List`/`Form`.
    static let debugProperties: UInt32 = 0b11011
}

@Observable
final class GlobalState {
    static let shared = GlobalState()
    var isEnabled = true
}
