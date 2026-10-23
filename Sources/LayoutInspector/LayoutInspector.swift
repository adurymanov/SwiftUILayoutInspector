import Foundation
import Observation
#if LayoutInspectorEngine && os(iOS)
import os
#endif

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
    /// Turns the inspector on for this process. Call it once, before the first SwiftUI view of the app is
    /// created – not just before the inspected one: `App.init`, or
    /// `application(_:willFinishLaunchingWithOptions:)` before the first `UIHostingController`.
    ///
    /// It does two things:
    /// - sets the environment variable `SWIFTUI_VIEW_DEBUG=27`. SwiftUI reads it once per process, when it
    ///   creates its first view graph, and from then on records a debug tree for every view: types, values
    ///   (paddings, frames, spacing, text attributes), positions and sizes – the data Xcode's view debugger
    ///   reads. Setting the variable in the scheme has the same effect;
    /// - sets the master switch ``isEnabled``.
    ///
    /// A call after SwiftUI has created a view is too late: the variable is not set,
    /// ``isSwiftUIGraphRecordingEnabled`` stays `false` and a warning is logged. The inspector then only sees
    /// the UIKit render tree.
    ///
    /// Xcode previews and `RunCodeSnippet` don't need it: in their processes (`XCODE_RUNNING_FOR_PREVIEWS=1`)
    /// the variable is set when the library is loaded.
    ///
    /// - Parameter isEnabled: `false` keeps SwiftUI untouched and turns every inspector off,
    ///   e.g. `bootstrap(isEnabled: settings.isDebugMenuEnabled)`.
    public static func bootstrap(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        #if LayoutInspectorEngine && os(iOS)
        guard isEnabled, getenv(debugEnvironmentKey) == nil else { return }
        if let host = SwiftUIGraphReader.existingHostingView() {
            GlobalState.shared.isBootstrapTooLate = true
            logger.error("""
                LayoutInspector.bootstrap() was called after SwiftUI created its first view \
                (\(TypeNames.shortClassName(host), privacy: .public)). SwiftUI reads SWIFTUI_VIEW_DEBUG once per \
                process, so its view graph is not recorded and the inspector only sees the UIKit render tree. \
                Call bootstrap() in App.init or before the first UIHostingController is created.
                """)
            return
        }
        setenv(debugEnvironmentKey, String(debugProperties), 1)
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

    /// Whether SwiftUI records its debug view graph in this process: ``bootstrap(isEnabled:)`` was called in
    /// time, or `SWIFTUI_VIEW_DEBUG` is set in the scheme.
    public static var isSwiftUIGraphRecordingEnabled: Bool {
        #if LayoutInspectorEngine && os(iOS)
        getenv(debugEnvironmentKey) != nil
        #else
        false
        #endif
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

    #if LayoutInspectorEngine && os(iOS)
    static let logger = Logger(subsystem: "LayoutInspector", category: "bootstrap")
    static let debugEnvironmentKey = "SWIFTUI_VIEW_DEBUG"

    /// `_ViewDebug.Property` bits: type | value | position | size.
    /// `transform` is left out on purpose: it contains scroll geometry with infinite sizes, which makes
    /// SwiftUI's own JSON serialisation fail for screens with `List`/`Form`.
    static let debugProperties: UInt32 = 0b11011
    #endif
}

@Observable
final class GlobalState {
    static let shared = GlobalState()
    var isEnabled = true
    /// `bootstrap()` came after SwiftUI's first view graph: nothing is recorded in this process.
    var isBootstrapTooLate = false
}
