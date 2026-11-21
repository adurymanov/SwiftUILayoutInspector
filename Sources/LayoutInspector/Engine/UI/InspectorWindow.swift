#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import Combine
import SwiftUI
import UIKit

/// Transparent window above the app: the overlay and the toolbar. Touches pass through to the app
/// everywhere except the toolbar and – when tap selection is on – the inspected area.
final class InspectorWindow: UIWindow {
    let root: InspectorRootViewController

    init(windowScene: UIWindowScene, session: InspectorSession) {
        root = InspectorRootViewController(session: session)
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        rootViewController = root
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Above the window of the inspected content: apps host debug tools and overlays in windows of their own,
    /// often far above `.alert`.
    static func level(above host: UIWindow?) -> UIWindow.Level {
        let floor = UIWindow.Level.alert.rawValue + 1
        return UIWindow.Level(rawValue: max(floor, (host?.windowLevel.rawValue ?? 0) + 1))
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        guard hit === root.view || hit === root.tapCatcher else { return hit }
        // An open menu closes on a tap anywhere, and only if the tap stays in this window.
        if isMenuPresented { return root.view }
        return root.session.catchesTap(at: convert(point, to: root.view)) ? root.tapCatcher : nil
    }

    /// The pill's menu: UIKit adds its container to the window while it is open.
    private var isMenuPresented: Bool {
        subviews.contains { !$0.isHidden && NSStringFromClass(type(of: $0)).contains("ContextMenu") }
    }
}

final class InspectorRootViewController: UIViewController {
    let session: InspectorSession
    let tapCatcher = UIView()
    private var pill: UIHostingController<InspectorToolbar>!
    private var pillX: NSLayoutConstraint!
    private var pillY: NSLayoutConstraint!
    private var placedInBounds: CGSize?
    private var dragOrigin: CGPoint?
    private var subscriptions: Set<AnyCancellable> = []

    init(session: InspectorSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        for v in [session.overlay, tapCatcher] {
            v.frame = view.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(v)
        }
        tapCatcher.backgroundColor = .clear
        tapCatcher.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))

        pill = UIHostingController(rootView: InspectorToolbar(session: session))
        embed(pill)
        pillX = pill.view.centerXAnchor.constraint(equalTo: view.leadingAnchor)
        pillY = pill.view.centerYAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([pillX, pillY])
        pill.view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))

        session.$configuration.map(\.toolbar).removeDuplicates()
            .sink { [weak self] toolbar in
                self?.pill.view.isHidden = toolbar == .hidden
                self?.view.setNeedsLayout()
            }
            .store(in: &subscriptions)
    }

    private func embed(_ child: UIHostingController<some View>) {
        child.view.backgroundColor = .clear
        child.sizingOptions = [.intrinsicContentSize]
        addChild(child)
        view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if dragOrigin == nil {
            if placedInBounds != view.bounds.size {
                placedInBounds = view.bounds.size
                movePill(to: ToolbarPosition.center(in: view.bounds) ?? defaultPillCenter)
            } else {
                movePill(to: CGPoint(x: pillX.constant, y: pillY.constant))
            }
        }
    }

    /// Where the pill may be: the safe area above the keyboard.
    private var pillArea: CGRect {
        var area = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 8, dy: 4)
        area.size.height = min(area.maxY, view.keyboardLayoutGuide.layoutFrame.minY - 4) - area.minY
        return area
    }

    private var defaultPillCenter: CGPoint {
        CGPoint(x: pillArea.maxX, y: pillArea.maxY)
    }

    private func movePill(to center: CGPoint) {
        let size = pill.view.intrinsicContentSize
        let area = pillArea
        let x = max(area.minX + size.width / 2, min(center.x, area.maxX - size.width / 2))
        let y = max(area.minY + size.height / 2, min(center.y, area.maxY - size.height / 2))
        if pillX.constant != x { pillX.constant = x }
        if pillY.constant != y { pillY.constant = y }
        let inLowerHalf = !pill.view.isHidden && y > view.bounds.midY
        session.pillDidMove(top: inLowerHalf ? y - size.height / 2 : nil)
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            dragOrigin = CGPoint(x: pillX.constant, y: pillY.constant)
        case .changed:
            guard let origin = dragOrigin else { return }
            let translation = pan.translation(in: view)
            movePill(to: CGPoint(x: origin.x + translation.x, y: origin.y + translation.y))
        default:
            dragOrigin = nil
            ToolbarPosition.save(CGPoint(x: pillX.constant, y: pillY.constant), in: view.bounds)
            view.setNeedsLayout()
        }
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        session.handleTap(at: gesture.location(in: view))
    }

    /// The app's key window before the list's search field made this window key.
    private weak var appKeyWindow: UIWindow?

    /// Dev → Components list, as a sheet in the inspector's window. At the medium height the screen above stays
    /// undimmed, so a selected component can be seen.
    func presentComponentList() {
        guard presentedViewController == nil else { return }
        appKeyWindow = view.window?.windowScene?.keyWindow
        weak var sheet: UIViewController?
        let list = UIHostingController(rootView: ComponentListView(session: session, reveal: {
            guard let controller = sheet?.sheetPresentationController else { return }
            controller.animateChanges { controller.selectedDetentIdentifier = .medium }
        }, close: { [weak self] in
            self?.dismissComponentList(animated: true)
        }))
        sheet = list
        if let controller = list.sheetPresentationController {
            controller.detents = [.medium(), .large()]
            controller.selectedDetentIdentifier = .large
            controller.largestUndimmedDetentIdentifier = .medium
            controller.prefersGrabberVisible = true
            controller.delegate = self
        }
        present(list, animated: true)
    }

    func dismissComponentList(animated: Bool) {
        guard presentedViewController != nil else { return }
        dismiss(animated: animated)
        restoreAppKeyWindow()
    }

    private func restoreAppKeyWindow() {
        if let window = appKeyWindow, !window.isHidden, window !== view.window { window.makeKey() }
        appKeyWindow = nil
    }
}

extension InspectorRootViewController: UISheetPresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        restoreAppKeyWindow()
    }
}

/// The pill's place on screen, shared by every inspector and kept between launches. Stored relative to the screen
/// size, so it survives rotation.
private enum ToolbarPosition {
    private static let key = "LayoutInspector.toolbarCenter"

    static func center(in bounds: CGRect) -> CGPoint? {
        guard let unit = UserDefaults.standard.array(forKey: key) as? [Double], unit.count == 2 else { return nil }
        return CGPoint(x: unit[0] * bounds.width, y: unit[1] * bounds.height)
    }

    static func save(_ center: CGPoint, in bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        UserDefaults.standard.set([Double(center.x / bounds.width), Double(center.y / bounds.height)], forKey: key)
    }
}

/// The inspector's controls (SwiftUI): a round glass button that can be dragged anywhere and opens a menu with every
/// option. Picking a mode there highlights the screen; the button shows the capture's progress. Lives in the inspector window,
/// never in the inspected screen.
struct InspectorToolbar: View {
    @ObservedObject var session: InspectorSession

    var body: some View {
        if session.configuration.toolbar != .hidden {
            Menu { menu } label: { pill }
                .menuOrder(.fixed)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Layout inspector")
                .accessibilityValue(accessibilityState)
        }
    }

    private var mode: LayoutInspector.Mode { session.configuration.mode }

    // MARK: Pill

    private var pill: some View {
        icon
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .inspectorGlass(in: Circle())
    }

    /// The mode's icon while highlighting, with the capture's progress around it.
    private var icon: some View {
        ZStack {
            if let progress = session.captureProgress {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.04, progress))
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.15), value: progress)
            }
            Image(systemName: session.isHighlighting ? mode.systemImage : "viewfinder")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
        }
        .frame(width: 34, height: 34)
    }

    private var accessibilityState: String {
        if let progress = session.captureProgress { return "\(mode.title), capturing, \(Int(progress * 100)) percent" }
        return session.isHighlighting ? mode.title : "Off"
    }

    // MARK: Menu

    @ViewBuilder private var menu: some View {
        Section(status) {
            // Toggles, not a Picker: the Dev submenu sets the same mode, and a Picker without a tag for it would
            // hold an invalid selection.
            modeToggle(nil, title: "Off", systemImage: "eye.slash")
            ForEach(LayoutInspector.Mode.allCases.filter { !$0.isDevelopmentTool }) { mode in
                modeToggle(mode, title: mode.title, systemImage: mode.systemImage)
            }
            devMenu
        }
        ControlGroup {
            Button { session.beginCapture() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(!session.isHighlighting)
            ShareLink(item: session.reportText ?? "") { Label("Share report", systemImage: "square.and.arrow.up") }
                .disabled(session.capture == nil)
        }
        Section {
            Toggle(isOn: $session.configuration.showsLabels) { Label("Labels", systemImage: "tag") }
            Toggle(isOn: $session.configuration.showsGrid) { Label("Grid", systemImage: "grid") }
        }
        .menuActionDismissBehavior(.disabled)
        Section {
            Button(role: .destructive) { session.configuration.isEnabled = false } label: {
                Label("Close inspector", systemImage: "xmark")
            }
        }
    }

    /// Tools for developing views rather than checking their layout.
    private var devMenu: some View {
        Menu {
            ForEach(LayoutInspector.Mode.allCases.filter(\.isDevelopmentTool)) { mode in
                if mode == .rerenders && !RenderProfiler.isAvailable {
                    Button {} label: { Label("\(mode.title) – not available on this iOS", systemImage: mode.systemImage) }
                        .disabled(true)
                } else {
                    modeToggle(mode, title: mode.title, systemImage: mode.systemImage)
                }
            }
            if session.isHighlighting && mode == .rerenders && session.renderCounts?.isGraphFound == true {
                Button { session.resetRenderCounts() } label: {
                    Label("Reset counts", systemImage: "arrow.counterclockwise")
                }
            }
            Section {
                Button { session.window?.root.presentComponentList() } label: {
                    Label("Components list", systemImage: "list.bullet.indent")
                }
                .disabled(session.capture == nil)
            }
        } label: {
            if session.isHighlighting && mode.isDevelopmentTool {
                Label("Dev · \(mode.title)", systemImage: "hammer")
            } else {
                Label("Dev", systemImage: "hammer")
            }
        }
    }

    /// Checked while the screen is highlighted in `mode` (`nil` – Off). Picking a mode highlights the screen in it.
    private func modeToggle(_ mode: LayoutInspector.Mode?, title: String, systemImage: String) -> some View {
        Toggle(isOn: Binding {
            highlightedMode.wrappedValue == mode
        } set: { isOn in
            if isOn || mode == nil { highlightedMode.wrappedValue = mode }
        }) {
            Label(title, systemImage: systemImage)
        }
    }

    /// `nil` – not highlighting. Picking a mode highlights the screen in it.
    private var highlightedMode: Binding<LayoutInspector.Mode?> {
        Binding {
            session.isHighlighting ? session.configuration.mode : nil
        } set: { mode in
            if let mode { session.highlight(mode) } else { session.stopHighlighting() }
        }
    }

    /// Shown as the mode section's header.
    private var status: String {
        if let progress = session.captureProgress { return "Capturing… \(Int(progress * 100))%" }
        guard session.isHighlighting else { return "Pick a mode to highlight the screen" }
        guard let capture = session.capture else { return "Waiting for the screen to settle" }
        if mode == .rerenders, let hottest = session.renderCounts?.hottest, hottest.entry.count > 0,
           let node = capture.node(withID: hottest.id) {
            return "Hottest: \(node.title) \(hottest.entry.label)"
        }
        let source = capture.isSwiftUIGraphAvailable ? "\(capture.swiftUINodes.count) nodes" : "Render tree only"
        return "\(source) · \(Int(capture.duration * 1000)) ms"
    }

}

extension View {
    /// Liquid Glass from iOS 26, a material before it.
    @ViewBuilder
    func inspectorGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

#endif
