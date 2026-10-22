#if LayoutInspectorEngine && os(iOS)
import UIKit
import Combine

/// Draws the current capture. Transparent, never intercepts touches.
final class InspectorOverlayView: UIView {
    var capture: InspectorCapture? { didSet { setNeedsDisplay() } }
    var options = InspectorRenderOptions() { didSet { setNeedsDisplay() } }
    /// Area to draw in (the inspected view), in `space` coordinates. `nil` – the whole overlay.
    var scope: CGRect? { didSet { if scope != oldValue { setNeedsDisplay() } } }
    /// Coordinate space the capture is resolved in. The overlay itself may be translated to follow
    /// a moving view (sheet, navigation transition); `space` never is.
    weak var space: UIView?
    /// Where the inspected view was (in `space`) when the overlay was drawn last.
    private(set) var drawnScopeOrigin: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let capture, let ctx = UIGraphicsGetCurrentContext() else { return }
        let space = space ?? self
        capture.resolveFrames(in: space)
        var area = bounds
        if let scope {
            area = scope.intersection(bounds)
            guard !area.isNull, !area.isEmpty else { return }
            ctx.clip(to: area)
        }
        drawnScopeOrigin = scope?.origin
        InspectorRenderer(capture: capture, space: space, bounds: area, options: options).draw(in: ctx)
    }
}

/// One inspector: what is inspected, its configuration, selection, auto-refresh and its window.
///
/// A session inspects either one view (`attach(anchor:)` – the `.layoutInspector` modifier) or a whole window.
/// Only the frontmost session (see `InspectorPresenter`) is on screen and runs its display link.
final class InspectorSession: ObservableObject {
    @Published var configuration: LayoutInspector.Configuration {
        didSet { configurationDidChange(from: oldValue) }
    }
    @Published var selectedID: Int? { didSet { syncOptions() } }
    @Published var measureTargetID: Int? { didSet { syncOptions() } }
    @Published private(set) var capture: InspectorCapture?
    @Published var isTreePresented = false

    /// Called when the configuration is changed from the toolbar (not from `apply(_:)`).
    var onConfigurationChange: ((LayoutInspector.Configuration) -> Void)?

    /// Root of the capture: the hosting view of the inspected view, or a window.
    private(set) weak var target: UIView?
    /// The inspected view (the modifier's background view). `nil` – the whole `target`.
    private(set) weak var anchor: UIView?
    private var excludedViews: [WeakView] = []

    let overlay = InspectorOverlayView()
    private(set) var window: InspectorWindow?

    private var isFrontmost = false
    private var isCovered = false
    private var isApplyingExternalChange = false
    private var toolbarTop: CGFloat?

    private var displayLink: CADisplayLink?
    private var frameCounter = 0
    private var layoutSignature = 0
    private var scrollSignature = 0
    private var anchorSize: CGSize?
    private var isMoving = false
    private var dirtySince: CFTimeInterval?
    private var lastCaptureTime: CFTimeInterval = 0
    private var refreshScheduled = false
    private var cachedReport: (capture: ObjectIdentifier, text: String)?

    init(configuration: LayoutInspector.Configuration) {
        self.configuration = configuration
        syncOptions()
    }

    // MARK: - Target

    /// Inspect the view `anchor` is the background of. The capture root is its closest hosting view.
    func attach(anchor: UIView) {
        guard anchor !== self.anchor || target == nil else { return }
        self.anchor = anchor
        var host = anchor.superview
        while let view = host, !SwiftUIGraphReader.isHostingView(view) { host = view.superview }
        target = host ?? anchor.window
        excludedViews = [WeakView(anchor)]
        // The platform-view container SwiftUI wraps the anchor into.
        if let container = anchor.superview, container !== host, container.subviews.count == 1 {
            excludedViews.append(WeakView(container))
        }
        resetCaptureState()
    }

    /// Inspect a whole window.
    func attach(window target: UIWindow) {
        anchor = nil
        self.target = target
        excludedViews = []
        resetCaptureState()
    }

    /// The app window the inspected content is in (`UIWindow.window` is `nil`).
    private var appWindow: UIWindow? {
        (target as? UIWindow) ?? target?.window ?? anchor?.window
    }

    private var excluded: [UIView] {
        excludedViews.compactMap(\.view) + (window.map { [$0] } ?? [])
    }

    private func resetCaptureState() {
        capture = nil
        overlay.capture = nil
        overlay.scope = nil
        overlay.transform = .identity
        selectedID = nil
        measureTargetID = nil
        layoutSignature = 0
        anchorSize = nil
        dirtySince = CACurrentMediaTime()
        lastCaptureTime = CACurrentMediaTime()
    }

    // MARK: - Configuration

    /// A change coming from the owner of the configuration (binding, `LayoutInspector.show`).
    func apply(_ configuration: LayoutInspector.Configuration) {
        guard configuration != self.configuration else { return }
        isApplyingExternalChange = true
        self.configuration = configuration
        isApplyingExternalChange = false
    }

    private func configurationDidChange(from old: LayoutInspector.Configuration) {
        if !isApplyingExternalChange { onConfigurationChange?(configuration) }
        if old.mode != configuration.mode { measureTargetID = nil }
        if old.isEnabled != configuration.isEnabled { updateVisibility() }
        if old.autoRefresh != configuration.autoRefresh, configuration.autoRefresh { dirtySince = CACurrentMediaTime() }
        syncOptions()
    }

    private func syncOptions() {
        var options = InspectorRenderOptions(configuration)
        options.selectedID = selectedID
        options.measureTargetID = measureTargetID
        if let toolbarTop {
            let bottom = overlay.scope.map { min($0.maxY, overlay.bounds.maxY) } ?? overlay.bounds.maxY
            options.cardBottomInset = max(12, bottom - toolbarTop + 8)
        } else {
            options.cardBottomInset = 24
        }
        overlay.options = options
    }

    /// Top edge of the toolbar in overlay coordinates, `nil` when there is no toolbar.
    func toolbarDidLayout(top: CGFloat?) {
        guard top != toolbarTop else { return }
        toolbarTop = top
        syncOptions()
    }

    // MARK: - Lifecycle

    func setFrontmost(_ frontmost: Bool) {
        guard frontmost != isFrontmost else { return }
        isFrontmost = frontmost
        if frontmost {
            // Let presentation animations and the first layout finish before the (possibly slow) first capture.
            dirtySince = CACurrentMediaTime()
            lastCaptureTime = CACurrentMediaTime()
        }
        updateVisibility()
    }

    func tearDown() {
        setFrontmost(false)
        window?.isHidden = true
        window = nil
        capture = nil
        overlay.capture = nil
        onConfigurationChange = nil
    }

    private func updateVisibility() {
        let visible = isFrontmost && configuration.isEnabled
        if visible {
            if window == nil, let scene = appWindow?.windowScene {
                let window = InspectorWindow(windowScene: scene, session: self)
                overlay.space = window.root.view
                self.window = window
            }
            window?.isHidden = isCovered
            startDisplayLink()
        } else {
            window?.isHidden = true
            isTreePresented = false
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Capture

    func refresh() {
        guard let target, let space = overlay.space else { return }
        let previousSelection = selectedNode
        let excluded = excluded
        let capture = LayoutCapture.capture(target, excluding: excluded)
        capture.resolveFrames(in: space)
        if ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_LOG"] != nil {
            NSLog("%@", "LayoutInspector capture: " + LayoutCapture.lastTimings.joined(separator: ", "))
        }
        layoutSignature = LayoutCapture.layoutSignature(of: target, excluding: excluded)
        scrollSignature = LayoutCapture.scrollSignature(of: target)
        lastCaptureTime = CACurrentMediaTime()
        dirtySince = nil
        self.capture = capture
        // Keep the selection across refreshes (ids change, so match by type + frame).
        if let previousSelection {
            let match = capture.swiftUINodes.first { $0.typeName == previousSelection.typeName && $0.anchor.rect == previousSelection.anchor.rect }
            selectedID = match?.id
        }
        overlay.capture = capture
    }

    /// Captures on a fresh main-queue turn, outside of the display-link callback and of SwiftUI transactions.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // The first capture of new content can take a second: let the toolbar show "Capturing…" first.
        let delay: TimeInterval = capture == nil ? 0.05 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            guard isFrontmost, configuration.isEnabled, !isCovered else { return }
            refresh()
        }
    }

    var selectedNode: InspectorNode? { selectedID.flatMap { capture?.node(withID: $0) } }

    var reportText: String? {
        guard let capture else { return nil }
        if let cachedReport, cachedReport.capture == ObjectIdentifier(capture) { return cachedReport.text }
        let text = LayoutReport.text(for: capture)
        cachedReport = (ObjectIdentifier(capture), text)
        return text
    }

    // MARK: - Display link

    /// Follows the inspected view (presentation, scrolling) every frame; re-captures when its content
    /// changes and settles.
    fileprivate func tick() {
        guard let target, appWindow != nil, let space = overlay.space else { return }

        if let anchor {
            let covered = isCoveredByPresentation(anchor)
            if covered != isCovered {
                isCovered = covered
                window?.isHidden = covered
                if covered { isTreePresented = false }
            }
            if covered { return }
            trackAnchor(anchor, in: space)
        }

        frameCounter += 1
        let scroll = LayoutCapture.scrollSignature(of: target)
        if scroll != scrollSignature {
            scrollSignature = scroll
            overlay.setNeedsDisplay()
        }
        guard configuration.autoRefresh || capture == nil else { return }
        guard frameCounter % 3 == 0, !refreshScheduled, !isMoving else { return }
        let now = CACurrentMediaTime()
        let signature = LayoutCapture.layoutSignature(of: target, excluding: excluded)
        // Don't re-capture back to back after an expensive (cold) capture, but never wait longer than 3 s.
        let minInterval = min(3, max(0.5, (capture?.duration ?? 0) * 2))
        if signature != layoutSignature {
            layoutSignature = signature
            if dirtySince == nil { dirtySince = now }
            // Animating content: don't wait forever for it to settle.
            if now - lastCaptureTime > 3 { scheduleRefresh() }
            return
        }
        if let dirty = dirtySince, now - dirty > 0.3, now - lastCaptureTime > minInterval || capture == nil {
            scheduleRefresh()
        }
    }

    /// Keeps the overlay on the inspected view while it moves (sheet presentation, navigation push,
    /// interactive dismissal): the drawing is translated and only redrawn when the view changes size.
    private func trackAnchor(_ anchor: UIView, in space: UIView) {
        guard let appWindow = anchor.window else { return }
        let model = anchor.convert(anchor.bounds, to: space)
        let presentationLayer = anchor.layer.presentation() ?? anchor.layer
        let windowLayer = appWindow.layer.presentation() ?? appWindow.layer
        let presented = appWindow.convert(presentationLayer.convert(presentationLayer.bounds, to: windowLayer), to: space)

        if anchorSize != model.size || overlay.scope == nil {
            anchorSize = model.size
            overlay.scope = model
            syncOptions()
        } else if overlay.scope?.origin != model.origin {
            // Moved without resizing (e.g. the sheet is being dragged): the drawing is still valid.
            overlay.scope = model
        }
        let drawn = overlay.drawnScopeOrigin ?? model.origin
        let transform = CGAffineTransform(translationX: presented.minX - drawn.x, y: presented.minY - drawn.y)
        if overlay.transform != transform { overlay.transform = transform }
        isMoving = abs(presented.minX - model.minX) > 0.5 || abs(presented.minY - model.minY) > 0.5
    }

    /// `true` when something is presented above the inspected view (a sheet, an alert…).
    private func isCoveredByPresentation(_ anchor: UIView) -> Bool {
        guard var top = anchor.window?.rootViewController else { return false }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard let topView = top.viewIfLoaded else { return false }
        return !anchor.isDescendant(of: topView)
    }

    // MARK: - Selection

    /// Whether a tap at `point` (overlay coordinates) belongs to the inspector rather than to the app.
    func catchesTap(at point: CGPoint) -> Bool {
        configuration.effectiveSelectsOnTap && (overlay.scope?.contains(point) ?? true)
    }

    func handleTap(at point: CGPoint) {
        guard let node = node(at: point) else { selectedID = nil; measureTargetID = nil; return }
        if configuration.mode == .measure, let selected = selectedID, measureTargetID == nil, selected != node.id {
            measureTargetID = node.id
        } else {
            selectedID = node.id
            measureTargetID = nil
        }
    }

    func node(at point: CGPoint) -> InspectorNode? {
        guard let capture, let space = overlay.space else { return nil }
        capture.resolveFrames(in: space)
        let pool: [InspectorNode]
        if configuration.mode == .uikit || !capture.isSwiftUIGraphAvailable {
            pool = capture.uikitNodes.filter { $0.kind == .uikitView }
        } else {
            pool = capture.swiftUINodes.filter { $0.kind != .host && $0.kind != .customModifier }
        }
        return pool
            .filter { $0.isVisible && $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
            .min { a, b in
                let aa = max(a.frame.width, 1) * max(a.frame.height, 1), ab = max(b.frame.width, 1) * max(b.frame.height, 1)
                if abs(aa - ab) < 1 { return a.depth > b.depth }
                return aa < ab
            }
    }

    func select(_ node: InspectorNode?) {
        selectedID = node?.id
        measureTargetID = nil
    }
}

private struct WeakView {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}

private final class DisplayLinkProxy: NSObject {
    weak var session: InspectorSession?
    init(_ session: InspectorSession) { self.session = session }
    @objc func tick() { session?.tick() }
}

#endif
