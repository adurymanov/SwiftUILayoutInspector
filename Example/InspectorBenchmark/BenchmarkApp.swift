import SwiftUI
import UIKit
import LayoutInspector

/// Measures what `SWIFTUI_VIEW_DEBUG` (what `LayoutInspector.bootstrap()` sets) costs the app's own SwiftUI work,
/// and what a capture costs when the inspector is open. Prints one `BENCH {json}` line and exits.
///
/// The app never calls `bootstrap()`: the runner sets the variable (or not) for the whole process,
/// e.g. `SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=27 xcrun simctl launch --console-pty … dev.layoutinspector.benchmark`.
@main
struct BenchmarkApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear.task { await Benchmark.run() }
        }
    }
}

enum Benchmark {
    static func run() async {
        UIApplication.shared.isIdleTimerDisabled = true   // a series of runs must not be cut by auto-lock
        try? await Task.sleep(for: .seconds(1))   // let the launch settle
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .normal + 1
        window.isHidden = false

        var result: [String: Double] = [:]
        result["recording"] = LayoutInspector.isSwiftUIGraphRecordingEnabled ? 1 : 0
        result["footprintStartMB"] = footprintMB()

        // Mounting: building the graph and the first layout of a new hosting controller.
        let list = ListModel(count: 100)
        result["mountList.coldMs"] = await mount(in: window) { CardList(model: list) }
        result["mountList.warmMs"] = await median(15) { await mount(in: window) { CardList(model: list) } }
        result["mountForm.coldMs"] = await mount(in: window) { SettingsForm() }
        result["mountForm.warmMs"] = await median(15) { await mount(in: window) { SettingsForm() } }

        // Updates of a mounted screen.
        _ = await mount(in: window) { CardList(model: list) }
        let host = window.rootViewController!.view!
        result["updateAllRowsMs"] = await median(100) {
            await measured(host) { list.tick += 1 }
        }
        var row = 0
        result["updateOneRowMs"] = await median(200) {
            row = (row + 1) % 100
            return await measured(host) { list.highlighted = row }
        }

        // Scrolling a lazy stack: rows are created on the way.
        let feed = ListModel(count: 2000)
        _ = await mount(in: window) { LazyFeed(model: feed) }
        let feedHost = window.rootViewController!.view!
        if let scroll = scrollView(in: feedHost) {
            var steps: [Double] = []
            for _ in 0..<150 {
                steps.append(await measured(feedHost) { scroll.contentOffset.y += 120 })
            }
            result["scrollStep.medianMs"] = steps.sorted()[steps.count / 2]
            result["scroll150Steps.totalMs"] = steps.reduce(0, +)
        }
        result["footprintEndMB"] = footprintMB()

        // The inspector open: what one capture costs.
        _ = await mount(in: window) { CardList(model: list) }
        var listCapture: InspectorCapture?
        result["captureList.coldMs"] = time { listCapture = LayoutInspector.capture(window) }
        result["captureList.nodes"] = Double(listCapture?.swiftUINodes.count ?? 0)
        result["captureList.components"] = Double(listCapture?.nodes(.component).count ?? 0)
        result["captureList.changedMs"] = await median(5) {
            list.tick += 1
            window.layoutIfNeeded()
            await settle()
            return time { _ = LayoutInspector.capture(window) }
        }
        result["captureList.unchangedMs"] = await median(5) {
            await settle()
            return time { _ = LayoutInspector.capture(window) }
        }
        _ = await mount(in: window) { SettingsForm() }
        result["captureForm.coldMs"] = time { _ = LayoutInspector.capture(window) }

        let meta: [String: String] = [
            "device": deviceModel(),
            "os": UIDevice.current.systemVersion,
            "SWIFTUI_VIEW_DEBUG": ProcessInfo.processInfo.environment["SWIFTUI_VIEW_DEBUG"] ?? "",
        ]
        let json = try! JSONSerialization.data(withJSONObject: ["meta": meta, "metrics": result], options: [.sortedKeys])
        print("BENCH " + String(decoding: json, as: UTF8.self))
        fflush(stdout)
        exit(0)
    }

    // MARK: - Measuring

    static func time(_ body: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        body()
        return (CACurrentMediaTime() - start) * 1000
    }

    static func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Creates a hosting controller, puts it on screen and lays it out (the old one is torn down outside the timing).
    static func mount<V: View>(in window: UIWindow, _ make: () -> V) async -> Double {
        window.rootViewController = nil
        CATransaction.flush()
        await settle()
        let ms = time {
            let host = UIHostingController(rootView: make())
            window.rootViewController = host
            host.view.layoutIfNeeded()
            CATransaction.flush()
        }
        await settle()
        return ms
    }

    /// A change and the layout pass that applies it.
    static func measured(_ host: UIView, _ change: () -> Void) async -> Double {
        let ms = time {
            change()
            host.setNeedsLayout()
            host.layoutIfNeeded()
            CATransaction.flush()
        }
        await Task.yield()
        return ms
    }

    static func median(_ count: Int, _ sample: () async -> Double) async -> Double {
        var values: [Double] = []
        for _ in 0..<count { values.append(await sample()) }
        return values.sorted()[count / 2]
    }

    static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews { if let hit = scrollView(in: sub) { return hit } }
        return nil
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated + " (simulator)" }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
