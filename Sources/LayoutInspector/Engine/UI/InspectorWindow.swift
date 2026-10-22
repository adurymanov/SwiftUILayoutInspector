#if LayoutInspectorEngine && os(iOS)
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
        windowLevel = .alert + 1
        backgroundColor = .clear
        rootViewController = root
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        guard hit === root.view || hit === root.tapCatcher else { return hit }
        return root.session.catchesTap(at: convert(point, to: root.view)) ? root.tapCatcher : nil
    }
}

final class InspectorRootViewController: UIViewController {
    let session: InspectorSession
    let tapCatcher = UIView()
    private var panel: UIHostingController<InspectorToolbar>!
    private var leading: NSLayoutConstraint!
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

        panel = UIHostingController(rootView: InspectorToolbar(session: session))
        panel.view.backgroundColor = .clear
        panel.sizingOptions = [.intrinsicContentSize]
        addChild(panel)
        view.addSubview(panel.view)
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        leading = panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        NSLayoutConstraint.activate([
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            panel.view.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        panel.didMove(toParent: self)

        session.$configuration.map(\.toolbar).removeDuplicates()
            .sink { [weak self] in self?.layoutToolbar($0) }
            .store(in: &subscriptions)
    }

    private func layoutToolbar(_ toolbar: LayoutInspector.Toolbar) {
        panel.view.isHidden = toolbar == .hidden
        // Collapsed: only the button is touchable, the rest of the bottom edge stays with the app.
        leading.isActive = toolbar == .expanded
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        session.toolbarDidLayout(top: panel.view.isHidden ? nil : panel.view.frame.minY)
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        session.handleTap(at: gesture.location(in: view))
    }
}

/// The inspector's controls (SwiftUI). Lives in the inspector window, never in the inspected screen.
struct InspectorToolbar: View {
    @ObservedObject var session: InspectorSession

    var body: some View {
        switch session.configuration.toolbar {
        case .hidden: EmptyView()
        case .collapsed: collapsed
        case .expanded: expanded
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        Menu {
            Picker("Mode", selection: $session.configuration.mode) {
                ForEach(LayoutInspector.Mode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            Toggle("Labels", isOn: $session.configuration.showsLabels)
            Toggle("Tap to select", isOn: $session.configuration.selectsOnTap)
            Divider()
            Button { session.configuration.isEnabled = false } label: { Label("Close inspector", systemImage: "xmark") }
        } label: {
            Image(systemName: session.configuration.mode.systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        } primaryAction: {
            session.configuration.toolbar = .expanded
        }
        .accessibilityLabel("Layout inspector")
        .padding(.trailing, 14)
        .padding(.bottom, 4)
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 8) {
            if let node = session.selectedNode, session.configuration.mode != .measure {
                NodeDetailsView(node: node) { session.select(nil) }
                    .frame(maxHeight: 300)
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
            VStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LayoutInspector.Mode.allCases) { mode in
                            let selected = session.configuration.mode == mode
                            Button { session.configuration.mode = mode } label: {
                                Label(mode.title, systemImage: mode.systemImage)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(selected ? .white : .primary)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                HStack(spacing: 12) {
                    toggle("hand.tap", "Tap to select", session.configuration.effectiveSelectsOnTap) {
                        session.configuration.selectsOnTap.toggle()
                    }
                    toggle("tag", "Labels", session.configuration.showsLabels) { session.configuration.showsLabels.toggle() }
                    toggle("grid", "Grid", session.configuration.showsGrid) { session.configuration.showsGrid.toggle() }
                    Button { session.isTreePresented = true } label: { Image(systemName: "list.bullet.indent") }
                        .accessibilityLabel("View tree")
                        .disabled(session.capture == nil)
                    Button { session.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                    if let report = session.reportText {
                        ShareLink(item: report) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share layout report")
                    }
                    Spacer(minLength: 0)
                    status
                    Button { session.configuration.toolbar = .collapsed } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Collapse")
                    Button { session.configuration.isEnabled = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close inspector")
                }
                .font(.body.weight(.semibold))
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .sheet(isPresented: $session.isTreePresented) {
            if let capture = session.capture {
                NodeTreeView(capture: capture) { node in
                    session.select(node)
                    session.isTreePresented = false
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var status: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let c = session.capture {
                Text(c.isSwiftUIGraphAvailable ? "\(c.swiftUINodes.count) nodes" : "render tree")
                    .foregroundStyle(c.isSwiftUIGraphAvailable ? Color.secondary : Color.orange)
                Text("\(Int(c.duration * 1000)) ms")
                    .foregroundStyle(.secondary)
            } else {
                Text("Capturing…").foregroundStyle(.secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    private func toggle(_ symbol: String, _ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

#endif
