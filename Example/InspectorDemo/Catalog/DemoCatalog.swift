import SwiftUI
@_spi(Diagnostics) import LayoutInspector

/// Demo screens, inspector settings and the way a screen is opened.
struct DemoCatalog: View {
    enum Presentation: String, CaseIterable, Identifiable {
        case push, sheet, fullScreen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .push: "Push"
            case .sheet: "Sheet"
            case .fullScreen: "Full screen"
            }
        }
    }

    @State private var inspector = LaunchOptions.configuration
    @State private var presentation = LaunchOptions.presentation ?? .push
    @State private var path: [DemoScreen] = []
    @State private var sheet: DemoScreen?
    @State private var fullScreen: DemoScreen?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Screens") {
                    ForEach(DemoScreen.allCases) { screen in
                        Button { open(screen) } label: { row(screen) }
                    }
                }
                Section {
                    Picker("Open as", selection: $presentation) {
                        ForEach(Presentation.allCases) { Text($0.title).tag($0) }
                    }
                    LayoutInspectorSettings($inspector)
                } header: {
                    Text("Layout inspector")
                }
                Section {
                    Button("Inspect this window") { LayoutInspector.show(windowConfiguration) }
                } footer: {
                    Text("Without modifiers: inspects whatever the key window shows.")
                }
            }
            .navigationTitle("Layout Inspector")
            .navigationDestination(for: DemoScreen.self) { screen in
                screen.view.layoutInspector($inspector)
            }
        }
        .sheet(item: $sheet) { screen in
            NavigationStack { screen.view.toolbar { close { sheet = nil } } }
                .layoutInspector($inspector)
        }
        .fullScreenCover(item: $fullScreen) { screen in
            NavigationStack { screen.view.toolbar { close { fullScreen = nil } } }
                .layoutInspector($inspector)
        }
        .task { await openFromLaunchArguments() }
    }

    /// The same settings, but always on: the window inspector is shown and hidden with its own calls.
    private var windowConfiguration: LayoutInspector.Configuration {
        var configuration = inspector
        configuration.isEnabled = true
        return configuration
    }

    private func row(_ screen: DemoScreen) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.title).foregroundStyle(.primary)
                Text(screen.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: screen.symbol)
        }
    }

    private func close(_ action: @escaping () -> Void) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", action: action)
        }
    }

    private func open(_ screen: DemoScreen) {
        switch presentation {
        case .push: path.append(screen)
        case .sheet: sheet = screen
        case .fullScreen: fullScreen = screen
        }
    }

    /// `-screen profile -inspector spacing -presentation sheet -toolbar collapsed -select "Anna Petrova"`
    private func openFromLaunchArguments() async {
        if LaunchOptions.value("-window") != nil {
            try? await Task.sleep(for: .milliseconds(300))
            LayoutInspector.show(windowConfiguration)
        }
        guard let screen = LaunchOptions.screen else { return }
        open(screen)
        guard let query = LaunchOptions.value("-select") else { return }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if LayoutInspector.activeCapture?.containsLoadingIndicator == false, LayoutInspector.select(query) { return }
        }
    }
}

/// Launch arguments for screenshots and manual checks.
enum LaunchOptions {
    static func value(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: key) else { return nil }
        return i + 1 < args.count ? args[i + 1] : ""
    }

    static var screen: DemoScreen? { value("-screen").flatMap(DemoScreen.init(rawValue:)) }
    static var presentation: DemoCatalog.Presentation? { value("-presentation").flatMap(DemoCatalog.Presentation.init(rawValue:)) }

    static var configuration: LayoutInspector.Configuration {
        var configuration = LayoutInspector.Configuration(isEnabled: false)
        if let mode = value("-inspector").flatMap(LayoutInspector.Mode.init(rawValue:)) {
            configuration.isEnabled = true
            configuration.mode = mode
        }
        if let toolbar = value("-toolbar").flatMap(LayoutInspector.Toolbar.init(rawValue:)) {
            configuration.toolbar = toolbar
        }
        return configuration
    }
}
