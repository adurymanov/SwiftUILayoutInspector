import SwiftUI
import LayoutInspector

@main
struct InspectorDemoApp: App {
    init() {
        #if DEBUG
        // Must happen before the first SwiftUI view is created.
        LayoutInspector.bootstrap()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Color.clear   // tests build their own windows
            } else {
                DemoCatalog()
            }
        }
    }
}
