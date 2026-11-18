import SwiftUI

extension View {
    /// Shows the layout inspector over this view.
    ///
    /// ```swift
    /// ProfileScreen()
    ///     .layoutInspector(.spacing, isEnabled: showsLayout)
    /// ```
    ///
    /// The overlay covers exactly this view and follows it: scrolling, data loading, sheet and navigation
    /// transitions. Changes made from the inspector's toolbar stay local to the view; pass a binding to
    /// ``layoutInspector(_:)-(Binding<LayoutInspector.Configuration>)`` to keep them.
    public func layoutInspector(_ mode: LayoutInspector.Mode = .components, isEnabled: Bool = true) -> some View {
        layoutInspector(LayoutInspector.Configuration(isEnabled: isEnabled, mode: mode))
    }

    /// Shows the layout inspector over this view, configured with `configuration`.
    ///
    /// Changes made from the inspector's toolbar stay local to the view and are replaced when
    /// `configuration` changes.
    public func layoutInspector(_ configuration: LayoutInspector.Configuration) -> some View {
        #if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
        modifier(LocalConfigurationModifier(initial: configuration))
        #else
        self
        #endif
    }

    /// Shows the layout inspector over this view and keeps `configuration` in sync with it in both directions:
    /// change the value to reconfigure the inspector at runtime; switching the mode, toggling labels or
    /// closing the inspector from its toolbar writes back.
    ///
    /// ```swift
    /// @State private var inspector = LayoutInspector.Configuration(mode: .typography, toolbar: .collapsed)
    ///
    /// CheckoutScreen()
    ///     .layoutInspector($inspector)
    /// ```
    ///
    /// When `configuration.isEnabled` is `false` there is no overlay, no window and no capturing. Toggling it
    /// keeps the identity of the inspected view, so its state is never reset.
    public func layoutInspector(_ configuration: Binding<LayoutInspector.Configuration>) -> some View {
        #if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
        modifier(InspectorModifier(configuration: configuration))
        #else
        self
        #endif
    }
}
