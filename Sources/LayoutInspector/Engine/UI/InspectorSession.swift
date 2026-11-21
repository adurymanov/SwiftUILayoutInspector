#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
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
    /// The overlay is on: captures run and are drawn. Off: nothing is captured until a mode is picked in the menu.
    @Published private(set) var isHighlighting: Bool
    /// Progress of the capture in flight, 0…1; `nil` when none is running.
    @Published private(set) var captureProgress: Double?

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
    /// Top edge of the pill in overlay coordinates while it is in the lower half; overlay cards stay above it.
    private var pillTop: CGFloat?
    private var isCovered = false
    private var isApplyingExternalChange = false

    private var displayLink: CADisplayLink?
    private var frameCounter = 0
    private var layoutSignature = 0
    private var scrollSignature = 0
    private var isMoving = false
    private var dirtySince: CFTimeInterval?
    private var lastCaptureTime: CFTimeInterval = 0
    private var job: LayoutCapture.Job?
    /// When the capture in flight started, and whether its progress is shown right away.
    private var jobStart: CFTimeInterval = 0
    private var jobShowsProgress = false
    /// The layout the capture in flight started from: a change during the capture triggers the next one.
    private var jobSignature = 0
    private var stepScheduled = false
    private var cachedReport: (capture: ObjectIdentifier, text: String)?

    init(configuration: LayoutInspector.Configuration) {
        self.configuration = configuration
        isHighlighting = configuration.highlightsOnAppear
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

    /// A whole-window session moves to whichever window is in front (see `InspectorPresenter.frontWindow()`).
    var followsFrontWindow = false

    /// Inspect a whole window.
    func attach(window target: UIWindow) {
        anchor = nil
        self.target = target
        excludedViews = []
        resetCaptureState()
    }

    /// The inspected content still exists. Its screen can be destroyed without `dismantleUIView` or a move out
    /// of the window, e.g. together with a window of its own.
    var isAttached: Bool { target != nil }

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
        if let pillTop {
            let bottom = overlay.scope.map { min($0.maxY, overlay.bounds.maxY) } ?? overlay.bounds.maxY
            options.cardBottomInset = max(24, bottom - pillTop + 8)
        } else {
            options.cardBottomInset = 24
        }
        overlay.options = options
    }

    func pillDidMove(top: CGFloat?) {
        guard top != pillTop else { return }
        pillTop = top
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
            window?.windowLevel = InspectorWindow.level(above: appWindow)
            window?.isHidden = isCovered
            startDisplayLink()
        } else {
            // A hidden window is released here, not kept for later: the scene retains every window attached to it,
            // and the window retains the session. Detaching waits a turn because this can run from the window's own
            // toolbar action.
            if let window {
                window.isHidden = true
                DispatchQueue.main.async { window.windowScene = nil }
            }
            window = nil
            cancelCapture()
            // The next window lays the shared overlay out from scratch; a translation left by a transition would shift it.
            overlay.transform = .identity
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

    /// Captures at once, blocking the main thread for the whole capture.
    func refresh() {
        guard let target, overlay.space != nil else { return }
        cancelCapture()
        isHighlighting = true
        let signature = LayoutCapture.layoutSignature(of: target, excluding: excluded)
        finish(LayoutCapture.capture(target, excluding: excluded), signature: signature)
    }

    /// Starts a capture that runs a few steps per frame (see `runCaptureSteps()`), publishing its progress.
    /// A capture nobody asked for (the content changed) shows progress only once it takes noticeable time, so quick
    /// re-captures don't make the button flicker.
    func beginCapture(requested: Bool = true) {
        guard let target, isHighlighting else { return }
        job = LayoutCapture.Job(root: target, excluding: excluded)
        jobSignature = LayoutCapture.layoutSignature(of: target, excluding: excluded)
        jobStart = CACurrentMediaTime()
        jobShowsProgress = requested
        captureProgress = requested ? 0 : nil
    }

    private func cancelCapture() {
        job = nil
        captureProgress = nil
    }

    /// Highlights the screen in `mode`, capturing it first if it is not highlighted yet. Switching between modes of
    /// a highlighted screen only redraws: one capture serves every mode.
    func highlight(_ mode: LayoutInspector.Mode) {
        configuration.mode = mode
        guard !isHighlighting else { return }
        isHighlighting = true
        beginCapture()
    }

    func stopHighlighting() {
        guard isHighlighting else { return }
        isHighlighting = false
        cancelCapture()
        capture = nil
        overlay.capture = nil
        selectedID = nil
        measureTargetID = nil
    }

    /// Steps run on a fresh main-queue turn, outside of the display-link callback and of SwiftUI transactions,
    /// and the next turn only comes with the next frame: the pill's progress is drawn in between.
    private func scheduleCaptureSteps() {
        guard !stepScheduled else { return }
        stepScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            stepScheduled = false
            runCaptureSteps()
        }
    }

    private func runCaptureSteps() {
        guard let job else { return }
        guard isFrontmost, configuration.isEnabled, isHighlighting, !isCovered else { cancelCapture(); return }
        if job.step(budget: 0.012), let capture = job.result {
            cancelCapture()
            finish(capture, signature: jobSignature)
        } else if jobShowsProgress || CACurrentMediaTime() - jobStart > 0.3 {
            captureProgress = job.progress
        }
    }

    /// `signature` – the layout the capture started from. If it has changed since, the next tick re-captures.
    private func finish(_ capture: InspectorCapture, signature: Int) {
        guard let target, let space = overlay.space else { return }
        let previousSelection = selectedNode
        let excluded = excluded
        capture.resolveFrames(in: space)
        if ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_LOG"] != nil {
            NSLog("%@", "LayoutInspector capture: " + LayoutCapture.lastTimings.joined(separator: ", "))
        }
        CaptureDump.writeIfRequested(capture)
        layoutSignature = signature
        scrollSignature = LayoutCapture.scrollSignature(of: target)
        lastCaptureTime = CACurrentMediaTime()
        dirtySince = LayoutCapture.layoutSignature(of: target, excluding: excluded) == signature ? nil : CACurrentMediaTime()
        self.capture = capture
        // Keep the selection across refreshes (ids change, so match by type + frame).
        if let previousSelection {
            let match = capture.swiftUINodes.first { $0.typeName == previousSelection.typeName && $0.anchor.rect == previousSelection.anchor.rect }
            selectedID = match?.id
        }
        overlay.capture = capture
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
        if followsFrontWindow, frameCounter % 10 == 0, let front = InspectorPresenter.frontWindow(), front !== target {
            retarget(to: front)
        }
        // The inspected screen went away without leaving its window, e.g. together with a window of its own.
        if !followsFrontWindow, target == nil || appWindow?.isHidden == true {
            InspectorPresenter.shared.deactivate(self)
            return
        }
        guard let target, appWindow != nil, let space = overlay.space else {
            frameCounter += 1
            return
        }

        if let anchor {
            let covered = isCoveredByPresentation(anchor)
            if covered != isCovered {
                isCovered = covered
                window?.isHidden = covered
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
        if job != nil {
            scheduleCaptureSteps()
            return
        }
        guard isHighlighting, configuration.autoRefresh || capture == nil else { return }
        guard frameCounter % 3 == 0, !isMoving else { return }
        let now = CACurrentMediaTime()
        let signature = LayoutCapture.layoutSignature(of: target, excluding: excluded)
        // Don't re-capture back to back after an expensive (cold) capture, but never wait longer than 3 s.
        let minInterval = min(3, max(0.5, (capture?.duration ?? 0) * 2))
        if signature != layoutSignature {
            layoutSignature = signature
            if dirtySince == nil { dirtySince = now }
            // Animating content: don't wait forever for it to settle.
            if now - lastCaptureTime > 3 { beginCapture(requested: false) }
            return
        }
        if let dirty = dirtySince, now - dirty > 0.3, now - lastCaptureTime > minInterval || capture == nil {
            beginCapture(requested: capture == nil)
        }
    }

    /// Highlighting stays on: the new window is captured once it settles (`capture` is `nil` again).
    private func retarget(to front: UIWindow) {
        if ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_LOG"] != nil {
            NSLog("%@", "LayoutInspector: inspecting \(type(of: front)) at level \(front.windowLevel.rawValue)")
        }
        cancelCapture()
        attach(window: front)
        window?.windowLevel = InspectorWindow.level(above: front)
    }

    /// Keeps the overlay on the inspected view while it moves (sheet presentation, navigation transitions,
    /// detent changes). UIKit moves the view to its final place at once and animates only its presentation
    /// layer: the overlay is drawn at the final place and translated to where the view is on screen.
    private func trackAnchor(_ anchor: UIView, in space: UIView) {
        guard let appWindow = anchor.window else { return }
        let model = anchor.convert(anchor.bounds, to: space)
        let presentationLayer = anchor.layer.presentation() ?? anchor.layer
        let windowLayer = appWindow.layer.presentation() ?? appWindow.layer
        let presented = appWindow.convert(presentationLayer.convert(presentationLayer.bounds, to: windowLayer), to: space)

        if overlay.scope != model {
            let resized = overlay.scope?.size != model.size
            overlay.scope = model
            if resized { syncOptions() }
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
        isHighlighting && configuration.effectiveSelectsOnTap && (overlay.scope?.contains(point) ?? true)
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
