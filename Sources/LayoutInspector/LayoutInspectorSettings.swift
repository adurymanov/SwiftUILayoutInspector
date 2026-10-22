import SwiftUI

/// Ready-made rows for editing a ``LayoutInspector/Configuration``. Put them in your own `Form` or `List`:
///
/// ```swift
/// Form {
///     Section("Layout") {
///         LayoutInspectorSettings($inspector)
///     }
/// }
/// ```
public struct LayoutInspectorSettings: View {
    @Binding private var configuration: LayoutInspector.Configuration

    public init(_ configuration: Binding<LayoutInspector.Configuration>) {
        _configuration = configuration
    }

    public var body: some View {
        if LayoutInspector.isAvailable {
            Toggle(isOn: $configuration.isEnabled) {
                Label("Layout inspector", systemImage: "ruler")
            }
            if configuration.isEnabled {
                Picker("Mode", selection: $configuration.mode) {
                    ForEach(LayoutInspector.Mode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                Toggle("Labels", isOn: $configuration.showsLabels)
                Toggle("Grid", isOn: $configuration.showsGrid)
                if configuration.showsGrid {
                    Stepper("Grid step \(Int(configuration.gridSize)) pt", value: $configuration.gridSize, in: 2...64, step: 2)
                }
                Picker("Controls", selection: $configuration.toolbar) {
                    ForEach(LayoutInspector.Toolbar.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Tap to select", isOn: $configuration.selectsOnTap)
                Toggle("Refresh on changes", isOn: $configuration.autoRefresh)
                if !LayoutInspector.isSwiftUIGraphRecordingEnabled {
                    Label(GlobalState.shared.isBootstrapTooLate
                          ? "LayoutInspector.bootstrap() was called after the first SwiftUI view, only the render tree is available. Call it in App.init."
                          : "SwiftUI graph is not recorded, only the render tree is available. Call LayoutInspector.bootstrap() in App.init.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Label("Layout inspector is not included in this build", systemImage: "ruler")
                .foregroundStyle(.secondary)
        }
    }
}
