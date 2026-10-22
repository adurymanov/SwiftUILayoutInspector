#if LayoutInspectorEngine && os(iOS)
import SwiftUI
import UIKit

/// `.layoutInspector($configuration)`.
///
/// Adds an invisible UIKit view behind the content. It tells the inspector which hosting view to capture
/// and which area to draw over, and it follows the content through presentations and navigation.
/// The structure is the same whether the inspector is on or off, so toggling it never resets the content's state.
struct InspectorModifier: ViewModifier {
    @Binding var configuration: LayoutInspector.Configuration
    @State private var attachment = InspectorAttachment()

    func body(content: Content) -> some View {
        content.background {
            if GlobalState.shared.isEnabled && configuration.isEnabled {
                LayoutInspectorAnchor(attachment: attachment, configuration: $configuration)
            }
        }
    }
}

/// `.layoutInspector(configuration)`: the inspector owns the configuration, toolbar changes stay local
/// until the input changes.
struct LocalConfigurationModifier: ViewModifier {
    let initial: LayoutInspector.Configuration
    @State private var configuration: LayoutInspector.Configuration

    init(initial: LayoutInspector.Configuration) {
        self.initial = initial
        _configuration = State(initialValue: initial)
    }

    func body(content: Content) -> some View {
        content
            .modifier(InspectorModifier(configuration: $configuration))
            .onChange(of: initial) { _, new in configuration = new }
    }
}

/// The capture skips this view and everything SwiftUI wraps it in (see `SwiftUITreeBuilder.classify`).
struct LayoutInspectorAnchor: UIViewRepresentable {
    static let typeName = "LayoutInspectorAnchor"

    let attachment: InspectorAttachment
    @Binding var configuration: LayoutInspector.Configuration

    func makeUIView(context: Context) -> AnchorView {
        attachment.update($configuration)
        return AnchorView(attachment: attachment)
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        attachment.update($configuration)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) {
        view.attachment.detach()
    }

    final class AnchorView: UIView {
        let attachment: InspectorAttachment

        init(attachment: InspectorAttachment) {
            self.attachment = attachment
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachment.anchorDidMoveToWindow(self)
        }
    }
}

/// Connects one `.layoutInspector` modifier to its session.
final class InspectorAttachment {
    private(set) var session: InspectorSession?
    private var configuration: Binding<LayoutInspector.Configuration>?

    func update(_ configuration: Binding<LayoutInspector.Configuration>) {
        self.configuration = configuration
        session?.apply(configuration.wrappedValue)
    }

    func anchorDidMoveToWindow(_ anchor: UIView) {
        guard anchor.window != nil else {
            // Covered by a pushed screen, dismissed, or moved to another tab.
            if let session { InspectorPresenter.shared.deactivate(session) }
            return
        }
        let session = self.session ?? makeSession()
        session.attach(anchor: anchor)
        InspectorPresenter.shared.activate(session)
    }

    func detach() {
        guard let session else { return }
        self.session = nil
        InspectorPresenter.shared.deactivate(session)
        session.tearDown()
    }

    private func makeSession() -> InspectorSession {
        let session = InspectorSession(configuration: configuration?.wrappedValue ?? LayoutInspector.Configuration())
        session.onConfigurationChange = { [weak self] configuration in
            self?.configuration?.wrappedValue = configuration
        }
        self.session = session
        return session
    }
}

#endif
