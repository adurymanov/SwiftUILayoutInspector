#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit

/// Every `_UIHostingView<Content>` (and subclasses: `HostingView`, `CellHostingView`…) gets this for free:
/// `_viewDebugData()` is a public (underscored) SwiftUI API, the raw data behind the ObjC `makeViewDebugData`.
protocol ViewDebugDataProviding: AnyObject {
    func _viewDebugData() -> [_ViewDebug.Data]
}

extension _UIHostingView: ViewDebugDataProviding {}

/// Approach #1 – read SwiftUI's own view graph.
///
/// Every `_UIHostingView` (including `HostingView` inside `NavigationStack`, `CellHostingView` in `List`,
/// toolbar/platter hosts…) implements the ObjC method `makeViewDebugData`, the entry point Xcode's view
/// debugger uses, and `_viewDebugData()` behind it: the whole SwiftUI tree with view/modifier types, their
/// *values* (padding insets, frame constraints, stack spacing, resolved text attributes) and the laid-out
/// position/size of each node. `ViewDebugReader` reads it without SwiftUI's JSON.
///
/// The graph only records this data when `SWIFTUI_VIEW_DEBUG` is set before the first graph is created –
/// see `LayoutInspector.bootstrap()`.
enum SwiftUIGraphReader {
    static let selector = NSSelectorFromString("makeViewDebugData")

    static func isHostingView(_ view: UIView) -> Bool {
        view.responds(to: selector)
    }

    /// A hosting view already on screen: SwiftUI has created a view graph (and has read `SWIFTUI_VIEW_DEBUG`).
    /// `UIApplication.shared` is only touched if the application object exists – it doesn't in `App.init`.
    static func existingHostingView() -> UIView? {
        let sharedApplication = NSSelectorFromString("sharedApplication")
        guard let app = (UIApplication.self as AnyObject).perform(sharedApplication)?.takeUnretainedValue() as? UIApplication
        else { return nil }
        func find(in view: UIView) -> UIView? {
            if isHostingView(view) { return view }
            for subview in view.subviews { if let host = find(in: subview) { return host } }
            return nil
        }
        for case let scene as UIWindowScene in app.connectedScenes {
            for window in scene.windows { if let host = find(in: window) { return host } }
        }
        return nil
    }

    /// Runs `body` inside a SwiftUI update (`UpdateTrampoline`), giving it the function that reads the
    /// `_ViewDebug` data of `host`: the read needs an update. The capture encodes the values the data holds in
    /// updates too, although reflecting the copied values has not been seen to need one.
    /// `false` when `body` did not run: `host` is not a `_UIHostingView`, or SwiftUI did not run the update.
    @discardableResult
    static func inUpdate(of host: UIView, _ body: (_ readDebugData: () -> [_ViewDebug.Data]) -> Void) -> Bool {
        guard let provider = host as? ViewDebugDataProviding else { return false }
        var ran = false
        withoutActuallyEscaping(body) { body in
            UpdateTrampoline.shared.run(in: host.window) {
                ran = true
                body { provider._viewDebugData() }
            }
        }
        return ran
    }

    /// Drops subtrees that are not on screen: cells kept for reuse by lazy stacks, fully transparent views, the
    /// hidden copies made for accessibility.
    static func pruneHidden(_ node: RawDebugNode) {
        node.children.removeAll { child in
            switch child.base {
            case "HiddenForReuseEffect": return child.value?["isHiddenForReuse"]?.bool == true
            case "OpacityRendererEffect", "_OpacityEffect": return (child.value?["opacity"]?.number ?? 1) < 0.01
            // What `.accessibilityRepresentation { … }` gives VoiceOver: laid out on its own, never drawn.
            case "HiddenModifierAllowingAccessibility": return true
            default: return false
            }
        }
        node.children.forEach(pruneHidden)
    }
}

/// `_viewDebugData()` must run inside a SwiftUI update transaction (`Update.ensure`, internal).
/// Any `body` evaluation happens inside one, so we run the work from the body of a tiny private view.
final class UpdateTrampoline {
    static let shared = UpdateTrampoline()
    private var controller: UIHostingController<TrampolineView>?

    /// The work is reachable from the view only through this box, which drops it once the update is over:
    /// the hosting controller keeps its root view, the work must not outlive `run`.
    final class Work {
        var body: (() -> Void)?
        init(_ body: @escaping () -> Void) { self.body = body }
    }

    struct TrampolineView: View {
        let id: Int
        let work: Work
        var body: some View {
            if let body = work.body {
                work.body = nil
                body()
            }
            return Color.clear
        }
    }

    private var counter = 0

    func run(in window: UIWindow?, _ work: @escaping () -> Void) {
        counter += 1
        let box = Work(work)
        defer { box.body = nil }
        let view = TrampolineView(id: counter, work: box)
        if let controller {
            controller.rootView = view
        } else {
            let c = UIHostingController(rootView: view)
            c.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            c.view.backgroundColor = .clear
            c.view.isUserInteractionEnabled = false
            c.view.alpha = 0.011
            controller = c
        }
        guard let hostView = controller?.view else { return }
        // SwiftUI only updates graphs of views that live in a window.
        if let window, hostView.window !== window { window.addSubview(hostView) }
        hostView.setNeedsLayout()
        hostView.layoutIfNeeded()
        if box.body != nil { _ = controller?.sizeThatFits(in: CGSize(width: 1, height: 1)) }
        hostView.removeFromSuperview()
    }
}

/// Converts the raw debug tree of one hosting view into a compact semantic tree.
final class SwiftUITreeBuilder {
    private let host: UIView
    private var scrollCandidates: [UIScrollView]
    private var nextID: () -> Int

    init(host: UIView, nextID: @escaping () -> Int) {
        self.host = host
        self.nextID = nextID
        self.scrollCandidates = SwiftUITreeBuilder.scrollViews(in: host)
    }

    private struct Context {
        var space: UIView
        /// From the coordinates `_ViewDebug` measures in here to `space`: a translation, and the scale or rotation of
        /// the effects above (see `opensCoordinateSpace`).
        var transform: CGAffineTransform = .identity
        /// The box of the nearest view with geometry, in the coordinates of `transform`. A view without geometry of
        /// its own (a `Text` under `.offset`, a component, a glass) takes it.
        var local: CGRect
        /// `local` in `space`.
        var rect: CGRect
        var parentReadable: String = ""
        var insideControl: Bool = false
        var controlBase: String?
        var decorations: [String] = []
        weak var parent: InspectorNode?

        init(space: UIView, rect: CGRect, parent: InspectorNode?) {
            self.space = space
            self.local = rect
            self.rect = rect
            self.parent = parent
        }

        mutating func place(_ box: CGRect) {
            local = box
            rect = box.applying(transform)
        }
    }

    /// Modifiers after which `_ViewDebug` measures positions from the modifier itself (iOS 18, 26 and 27 alike):
    /// Liquid Glass, the geometry and drawing groups and the transform effects.
    private static let coordinateSpaceModifiers: Set<String> = [
        "GlassEffectModifier", "_GeometryGroupEffect", "_DrawingGroupEffect", "_ScaleEffect", "_RotationEffect",
        "_Rotation3DEffect", "_TransformEffect", "_ProjectionEffect",
    ]

    /// Modifiers that do it only when their effect moves the content (`.visualEffect` and `.scrollTransition` with
    /// a scale or an offset do, with only an opacity they do not), and SwiftUI's geometry effects the probes did not
    /// cover.
    private static let contentDependentSpaceModifiers: Set<String> = [
        "VisualEffectModifier", "ScrollTransitionModifier", "_FlipForRTLEffect", "_IgnoredByLayoutEffect",
    ]

    /// Positions below `raw` are measured from `raw`. For the modifiers that do it only sometimes, and for an app's
    /// own `GeometryEffect`, the geometry tells: the first measured view below lies inside `raw` only when its
    /// position is taken from `raw`'s corner. `box` is where `raw` is when it has no geometry of its own: an app's
    /// `GeometryEffect` right under a transition wrapper (a banking app's passcode dots) takes the box from above.
    static func opensCoordinateSpace(_ raw: RawDebugNode, box: CGRect) -> Bool {
        guard !raw.isSynthetic else { return false }
        let isApp = TypeNames.isAppType(raw.typeName)
        let name = TypeNames.shortName(of: raw.typeName)
        if !isApp, coordinateSpaceModifiers.contains(name) { return true }
        guard isApp || contentDependentSpaceModifiers.contains(name) else { return false }
        // A conformance check scans every conformance in the app the first time for a type: only for the few nodes
        // that get here, not for every node of the tree.
        let isGeometryEffect = raw.swiftValue is any GeometryEffect
        guard let outer = raw.geometry ?? (isGeometryEffect ? box : nil) else { return false }
        // At the origin of the space the corner is the same either way; open it so the effect's transform applies.
        if outer.origin == .zero { return isGeometryEffect }
        guard let inner = raw.children.lazy.compactMap({ $0.firstGeometry }).first else { return false }
        // Even with a translation (`visualEffect { $0.offset(x: 10) }`) the content is reported at the corner.
        return !outer.insetBy(dx: -1, dy: -1).contains(inner)
            && CGRect(origin: .zero, size: outer.size).insetBy(dx: -1, dy: -1).contains(inner)
    }

    /// What a modifier that opens a coordinate space does to its content, in the modifier's own coordinates. For the
    /// ones that are not a `GeometryEffect` (glass, `.visualEffect`) only where the content starts is known.
    static func effectTransform(of raw: RawDebugNode, size: CGSize) -> CGAffineTransform {
        func around(_ anchor: UnitPoint, _ transform: CGAffineTransform) -> CGAffineTransform {
            let a = CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
            return CGAffineTransform(translationX: -a.x, y: -a.y).concatenating(transform)
                .concatenating(CGAffineTransform(translationX: a.x, y: a.y))
        }
        if let value = raw.swiftValue {
            // A `GeometryEffect` says what it does (`scaleEffect`, `rotationEffect`, `transformEffect` and an app's own
            // effect alike: a banking app's passcode dots move theirs by half a dot). A perspective one
            // (`rotation3DEffect`, `projectionEffect`) is left out: a box cannot follow it.
            guard let effect = value as? any GeometryEffect else { return .identity }
            let p = effect.effectValue(size: size)
            guard abs(p.m13) < 1e-9, abs(p.m23) < 1e-9, abs(p.m33 - 1) < 1e-9 else { return .identity }
            return CGAffineTransform(a: p.m11, b: p.m12, c: p.m21, d: p.m22, tx: p.m31, ty: p.m32)
        }
        // Read through SwiftUI's own encoding (data of a layout this reader does not know).
        let value = raw.value
        let anchor = UnitPoint(x: value?.at("anchor", "x")?.number ?? 0.5, y: value?.at("anchor", "y")?.number ?? 0.5)
        switch TypeNames.shortName(of: raw.typeName) {
        case "_ScaleEffect":
            guard let scale = value?["scale"]?.size else { return .identity }
            return around(anchor, CGAffineTransform(scaleX: scale.width, y: scale.height))
        case "_RotationEffect":
            guard let radians = value?.at("angle", "radians")?.number else { return .identity }
            return around(anchor, CGAffineTransform(rotationAngle: radians))
        default:
            return .identity
        }
    }

    private static func isSwiftUI(_ raw: RawDebugNode, _ name: String) -> Bool {
        TypeNames.shortName(of: raw.typeName) == name && !TypeNames.isAppType(raw.typeName)
    }

    func build(roots: [RawDebugNode]) -> InspectorNode {
        let hostNode = InspectorNode(
            id: nextID(), kind: .host,
            title: TypeNames.shortClassName(host),
            typeName: TypeNames.name(of: type(of: host)),
            anchor: NodeAnchor(view: host, rect: host.bounds)
        )
        for root in roots {
            visit(root, Context(space: host, rect: host.bounds, parent: hostNode))
        }
        sortChildren(hostNode)
        return hostNode
    }

    // MARK: - Walk

    private func visit(_ raw: RawDebugNode, _ incoming: Context) {
        var ctx = incoming
        if let g = raw.geometry { ctx.place(g) }
        // Positions below `.glassEffect`, `.geometryGroup()`, the transform effects and the like are measured from
        // the modifier (see `opensCoordinateSpace`), before its scale or rotation. The content of a
        // `GlassEffectContainer` stays in the space around it; its storage (SwiftUI drawing the glass) is measured
        // from the container and left out. Under `.offset` the glass has no geometry: it takes the box of its parent
        // moved by the offset, and so does a component whose body starts with it.
        if Self.isSwiftUI(raw, "ContainerStorageView") { return }
        let opensSpace = Self.opensCoordinateSpace(raw, box: ctx.local)

        let classification = classify(raw, ctx)
        var childCtx = ctx
        childCtx.parentReadable = raw.readable
        if opensSpace {
            childCtx.transform = Self.effectTransform(of: raw, size: ctx.local.size)
                .concatenating(CGAffineTransform(translationX: ctx.local.minX, y: ctx.local.minY))
                .concatenating(ctx.transform)
            childCtx.place(CGRect(origin: .zero, size: ctx.local.size))
        }

        switch classification {
        case .skipSubtree:
            return

        case let .decoration(text):
            childCtx.decorations.append(text)

        case let .offset(size):
            // Positions below `.offset` already include it (iOS 18, 26 and 27): only the views without geometry of
            // their own, which take the box measured above it, are moved here.
            childCtx.place(ctx.local.offsetBy(dx: size.width, dy: size.height))
            let node = makeNode(raw, ctx, kind: .offset, title: ".offset",
                                detail: "x \(size.width.pt) y \(size.height.pt)")
            node.info.offset = size
            childCtx.parent = node
            childCtx.decorations = []

        case .enterScroll:
            if let scroll = matchScrollView(for: ctx) {
                childCtx.space = scroll
                childCtx.transform = .identity
                childCtx.place(CGRect(origin: .zero, size: scroll.contentSize))
            }

        case .passThrough:
            break

        case .exitControl:
            childCtx.insideControl = false

        case let .keep(kind, title, detail, info, descend, isControl):
            let node = makeNode(raw, ctx, kind: kind, title: title, detail: detail, info: info)
            node.info.decorations = ctx.decorations
            childCtx.decorations = []
            childCtx.parent = node
            if isControl { childCtx.insideControl = true; childCtx.controlBase = title }
            if kind == .padding, let inner = innerBox(below: raw) {
                node.info.padding?.inner = NodeAnchor(view: ctx.space, rect: inner.applying(ctx.transform))
                // In the content's own units, like the declared insets: under a scale or a rotation the bands on
                // screen differ (the renderer draws them from the frames).
                let outer = ctx.local
                node.info.padding?.measured = EdgeValues(
                    top: inner.minY - outer.minY, leading: inner.minX - outer.minX,
                    bottom: outer.maxY - inner.maxY, trailing: outer.maxX - inner.maxX
                )
            }
            if !descend { return }
        }

        for child in raw.children {
            var c = childCtx
            if raw.children.count > 1 { c.decorations = [] }
            visit(child, c)
        }
    }

    private func makeNode(_ raw: RawDebugNode, _ ctx: Context, kind: NodeKind, title: String,
                          detail: String? = nil, info: NodeInfo = NodeInfo()) -> InspectorNode {
        var info = info
        if info.lazyRaw == nil, info.raw.isEmpty, !raw.isSynthetic {
            info.lazyRaw = Self.rawValues(of: raw, limit: 24)
        }
        let node = InspectorNode(
            id: nextID(), kind: kind, title: title, detail: detail,
            typeName: raw.typeName,
            anchor: NodeAnchor(view: ctx.space, rect: ctx.rect),
            info: info
        )
        ctx.parent?.add(node)
        return node
    }

    private static func rawValues(of raw: RawDebugNode, limit: Int) -> LazyRawValues {
        let value = raw.detachedValue()
        return LazyRawValues {
            var values: [(String, String)] = []
            value()?.flatten(into: &values, limit: limit)
            return values
        }
    }

    /// The first descendant that has its own geometry = the content box inside a padding, in the coordinates the
    /// padding is measured in.
    private func innerBox(below raw: RawDebugNode) -> CGRect? {
        var current = raw
        while current.children.count == 1 {
            current = current.children[0]
            if let g = current.geometry { return g }
        }
        // Multiple children (e.g. background + content): the content is the largest box.
        let boxes = current.children.compactMap { firstGeometry(in: $0) }
        return boxes.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    private func firstGeometry(in raw: RawDebugNode) -> CGRect? {
        if let g = raw.geometry { return g }
        for c in raw.children { if let g = firstGeometry(in: c) { return g } }
        return nil
    }

    // MARK: - Classification

    private enum Classification {
        case keep(NodeKind, String, String?, NodeInfo, descend: Bool, isControl: Bool)
        case passThrough
        case decoration(String)
        case offset(CGSize)
        case enterScroll
        case exitControl
        case skipSubtree
    }

    private static let controls: Set<String> = [
        "Button", "Toggle", "TextField", "SecureField", "Picker", "Slider", "Stepper", "DatePicker",
        "Menu", "Link", "NavigationLink", "ProgressView", "Gauge", "ShareLink", "ColorPicker", "Label",
        "LabeledContent", "TextEditor",
    ]

    private static let stacks: [String: StackInfo.Axis] = [
        "VStack": .vertical, "HStack": .horizontal, "ZStack": .depth,
        "LazyVStack": .vertical, "LazyHStack": .horizontal,
        "LazyVGrid": .grid, "LazyHGrid": .grid, "Grid": .grid, "GridRow": .horizontal,
        "VStackLayout": .vertical, "HStackLayout": .horizontal, "ZStackLayout": .depth,
    ]

    private static let internalMarkers = [
        "Configuration", "Resolved", "TupleContent", "Pack{", "StyleBody", "StyleLabel", "StyleContext",
        "StaticIf", "Bordered", "Borderless", "ButtonStyle", "_TextFieldStyleLabel", "CellModifier",
        "Platform", "ListStyle", "Accessibility", "Toolbar", "Navigation", "_ViewList_View",
    ]

    /// System-internal structure (button/toggle/list-row internals). Only the *content signature*
    /// (`VStack<ResolvedButtonStyleBody>`) is checked – full generic types mention everything nested inside.
    private func isInternal(_ raw: RawDebugNode, _ ctx: Context) -> Bool {
        let signatures = [raw.readable, ctx.parentReadable, raw.children.first?.readable ?? ""]
            .map(TypeNames.contentSignature(of:))
        return signatures.contains { h in Self.internalMarkers.contains { h.contains($0) } }
    }

    private func classify(_ raw: RawDebugNode, _ ctx: Context) -> Classification {
        let base = raw.base
        // Encoding a node's value is the expensive part of reading it: only the cases that use it touch it.
        var value: DebugAttribute? { raw.value }

        // The `.layoutInspector` modifier's own background view is not part of the inspected layout.
        if Self.isInspectorAnchor(raw.readable) { return .skipSubtree }
        if base == "_BackgroundModifier", raw.genericArguments.first.map(Self.isInspectorAnchor) == true { return .passThrough }

        // Inside a control everything is system styling until the user's label placeholder.
        if ctx.insideControl, !raw.readable.contains("Primitive"),
           ["StyleConfiguration.Label", "StyleConfiguration.Title", "StyleConfiguration.Icon", "StyleConfiguration.Content"]
            .contains(where: raw.readable.contains) {
            return .exitControl
        }

        // App-defined types: components & custom modifiers – this is the "component layout".
        if TypeNames.isAppType(raw.typeName) {
            let isModifier = ctx.parentReadable.contains(", \(raw.readable)>") || ctx.parentReadable.contains(", \(base)>")
            var info = NodeInfo()
            if !raw.isSynthetic { info.lazyRaw = Self.rawValues(of: raw, limit: 16) }
            let name = raw.isSynthetic ? raw.readable : TypeNames.shortName(of: raw.typeName)
            return .keep(isModifier ? .customModifier : .component, name, nil, info, descend: true, isControl: false)
        }

        switch base {
        case "SystemScrollView":
            return .enterScroll

        case "Text":
            var info = NodeInfo()
            info.text = textInfo(for: raw, rect: ctx.rect)
            let preview = info.text.map { "“\($0.string.prefix(40))\($0.string.count > 40 ? "…" : "")”" }
            return .keep(.text, "Text", preview, info, descend: false, isControl: false)

        case "Image", "AsyncImage":
            var info = NodeInfo()
            let name = Self.firstValuePart(raw, named: "name", maxDepth: 12)?.string
                ?? Self.firstValuePart(raw, named: "systemSymbol", maxDepth: 12)?.string ?? ""
            let location = Self.firstValuePart(raw, named: "location", maxDepth: 12)?.string ?? ""
            var natural: CGSize?
            if let resolved = raw.children.first.flatMap({ findNode($0, base: "Resolved") }),
               let px = Self.firstValuePart(resolved, named: "unrotatedPixelSize", maxDepth: 12)?.size,
               let scale = Self.firstValuePart(resolved, named: "scale", maxDepth: 12)?.number, scale > 0 {
                natural = CGSize(width: px.width / scale, height: px.height / scale)
            }
            info.image = ImageInfo(name: name, isSymbol: location == "system", naturalSize: natural)
            let detail = name.isEmpty ? nil : (location == "system" ? "􀎶 \(name)" : name)
            return .keep(.image, base, detail, info, descend: false, isControl: false)

        case "_ShapeView":
            if ctx.insideControl { return .passThrough }
            var info = NodeInfo()
            let shape = raw.genericArguments.first.map(TypeNames.base) ?? "Shape"
            info.shapeName = shape
            info.fill = describeStyle(Self.valuePart(raw, "style"))
            if let corner = Self.firstValuePart(raw, named: "cornerSize", maxDepth: 12)?.size, corner.width > 0 {
                info.decorations.append("cornerRadius \(corner.width.pt)")
            }
            return .keep(.shape, shape, info.fill, info, descend: false, isControl: false)

        case "Color":
            var info = NodeInfo()
            info.fill = describeStyle(value)
            return .keep(.color, "Color", info.fill, info, descend: false, isControl: false)

        case "Spacer":
            if ctx.insideControl { return .passThrough }
            var info = NodeInfo()
            info.spacerMinLength = Self.valuePart(raw, "minLength")?.number
            let detail = info.spacerMinLength.map { "≥\($0.pt)" }
            return .keep(.spacer, "Spacer", detail, info, descend: false, isControl: false)

        case "Divider":
            return .keep(.divider, "Divider", nil, NodeInfo(), descend: false, isControl: false)

        case "ScrollView":
            let axis = Self.firstValuePart(raw, named: "axes", maxDepth: 12)?.string ?? ""
            return .keep(.scroll, "ScrollView", axis.contains("horizontal") ? "horizontal" : nil, NodeInfo(), descend: true, isControl: false)

        case "List", "Form":
            return .keep(.list, base, nil, NodeInfo(), descend: true, isControl: false)

        case "SystemTextField":
            return .keep(.control, "TextField", nil, NodeInfo(), descend: false, isControl: true)

        case "Switch":
            return .keep(.control, "Toggle", "switch", NodeInfo(), descend: false, isControl: true)

        case "PlatformViewRepresentableAdaptor", "PlatformViewControllerRepresentableAdaptor":
            let wrapped = raw.genericArguments.first.map(TypeNames.base) ?? base
            // System bridges (NavigationStack, List…) and app representables already shown as components.
            if ctx.insideControl || wrapped.contains("Navigation") || wrapped.hasSuffix("Representable")
                || ctx.parentReadable == wrapped || ctx.parentReadable.hasSuffix(wrapped) { return .passThrough }
            return .keep(.platform, wrapped, "UIKit", NodeInfo(), descend: false, isControl: false)

        case "_PaddingLayout":
            var padding = PaddingInfo(declared: nil, edges: [])
            let edgesText = value?["edges"]?.string ?? ""
            padding.edges = ["top", "leading", "bottom", "trailing"].filter { edgesText.contains("Edge.\($0)") || edgesText.contains(".\($0)") }
            if let insets = value?["insets"], insets["top"] != nil {
                var e = EdgeValues(
                    top: insets["top"]?.number ?? 0, leading: insets["leading"]?.number ?? 0,
                    bottom: insets["bottom"]?.number ?? 0, trailing: insets["trailing"]?.number ?? 0
                )
                if !padding.edges.contains("top") { e.top = 0 }
                if !padding.edges.contains("leading") { e.leading = 0 }
                if !padding.edges.contains("bottom") { e.bottom = 0 }
                if !padding.edges.contains("trailing") { e.trailing = 0 }
                padding.declared = e
            }
            let internalPadding = isInternal(raw, ctx) || ctx.insideControl
            if ctx.insideControl { return .passThrough }
            padding.isSystem = internalPadding
            var info = NodeInfo()
            info.padding = padding
            info.isInternal = internalPadding
            return .keep(.padding, ".padding", paddingCode(padding), info, descend: true, isControl: false)

        case "_FrameLayout", "_FlexFrameLayout":
            if isInternal(raw, ctx) || ctx.insideControl { return .passThrough }
            let flexible = base == "_FlexFrameLayout"
            var rule = FrameRule(isFlexible: flexible)
            rule.width = value?["width"]?.number
            rule.height = value?["height"]?.number
            rule.minWidth = value?["minWidth"]?.number
            rule.idealWidth = value?["idealWidth"]?.number
            rule.maxWidth = value?["maxWidth"]?.number
            rule.minHeight = value?["minHeight"]?.number
            rule.idealHeight = value?["idealHeight"]?.number
            rule.maxHeight = value?["maxHeight"]?.number
            if let h = value?.at("alignment", "horizontal")?.string, let v = value?.at("alignment", "vertical")?.string {
                rule.alignment = alignmentName(horizontal: h, vertical: v)
            }
            var info = NodeInfo()
            info.frameRule = rule
            return .keep(flexible ? .flexFrame : .frame, ".frame", String(rule.code.dropFirst(".frame".count)), info, descend: true, isControl: false)

        case "_FixedSizeLayout":
            if isInternal(raw, ctx) || ctx.insideControl { return .passThrough }
            var info = NodeInfo()
            let h = value?["horizontal"]?.bool ?? true, v = value?["vertical"]?.bool ?? true
            info.fixedSize = (h, v)
            let detail = h && v ? "()" : "(horizontal: \(h), vertical: \(v))"
            return .keep(.fixedSize, ".fixedSize", detail, info, descend: true, isControl: false)

        case "_AspectRatioLayout":
            var info = NodeInfo()
            let ratio = value?["aspectRatio"]?.number
            let mode = value?["contentMode"]?.string?.lowercased() ?? "fit"
            info.aspectRatio = (ratio, mode)
            return .keep(.aspectRatio, ".aspectRatio", "(\(ratio?.pt ?? "nil"), .\(mode))", info, descend: true, isControl: false)

        case "_OffsetEffect":
            let size = value?["offset"]?.size ?? .zero
            return size == .zero ? .passThrough : .offset(size)

        case "_TraitWritingModifier" where raw.readable.contains("LayoutPriority"):
            var info = NodeInfo()
            info.layoutPriority = value?.first(named: "value").flatMap { $0.number }.map(Double.init)
            return .keep(.layoutPriority, ".layoutPriority", "(\(info.layoutPriority.map { CGFloat($0).pt } ?? "?"))", info, descend: true, isControl: false)

        case "_SafeAreaRegionsIgnoringLayout", "_SafeAreaIgnoringLayout":
            if isInternal(raw, ctx) || ctx.insideControl { return .passThrough }
            let edges = value?["edges"]?.string ?? ""
            return .keep(.ignoresSafeArea, ".ignoresSafeArea", edges.contains("top") && edges.contains("bottom") ? nil : edges, NodeInfo(), descend: true, isControl: false)

        case "_BackgroundStyleModifier", "_BackgroundModifier", "_BackgroundShapeModifier":
            if ctx.insideControl { return .passThrough }
            return .decoration(".background(\(describeStyle(Self.valuePart(raw, "style")) ?? raw.genericArguments.first.map(TypeNames.base) ?? ""))")
        case "_OverlayModifier", "_OverlayStyleModifier", "_OverlayShapeModifier":
            return .decoration(".overlay(\(raw.genericArguments.first.map(TypeNames.base) ?? ""))")
        case "_ClipEffect":
            let shape = raw.genericArguments.first.map(TypeNames.base) ?? ""
            if let corner = Self.firstValuePart(raw, named: "cornerSize", maxDepth: 12)?.size, corner.width > 0 {
                return .decoration(".clipShape(\(shape), r \(corner.width.pt))")
            }
            return .decoration(".clipShape(\(shape))")
        case "_ShadowEffect":
            let radius = value?["radius"]?.number ?? value?.first(named: "radius")?.number
            return .decoration(".shadow(r \(radius?.pt ?? "?"))")
        default:
            break
        }

        if Self.controls.contains(base) {
            if ctx.insideControl && isInternal(raw, ctx) { return .passThrough }
            // `Label<LabelStyleConfiguration.Title, …>` inside a `Label`: SwiftUI re-wrapping its own control.
            if ctx.controlBase == base && raw.readable.contains("Configuration") { return .passThrough }
            return .keep(.control, base, nil, NodeInfo(), descend: true, isControl: true)
        }

        if let axis = Self.stacks[base] {
            if isInternal(raw, ctx) || ctx.insideControl { return .passThrough }
            var info = NodeInfo()
            let spacing = Self.stackLayoutValue(raw, "spacing")?.number
            var alignment = Self.stackLayoutValue(raw, "alignment")
            if alignment?.string == nil, let h = alignment?["horizontal"]?.string, let v = alignment?["vertical"]?.string {
                info.stack = StackInfo(axis: axis, name: base, alignment: alignmentName(horizontal: h, vertical: v), spacing: spacing)
                alignment = nil
            } else {
                info.stack = StackInfo(axis: axis, name: base, alignment: alignment?.string?.lowercased(), spacing: spacing)
            }
            return .keep(.stack, base, stackDetail(info.stack!), info, descend: true, isControl: false)
        }

        // Custom `Layout` types show up as `_VariadicView.Tree<_LayoutRoot<FlowLayout>, …>`.
        if base == "_VariadicView.Tree", let first = raw.genericArguments.first, first.hasPrefix("_LayoutRoot<") {
            let layoutName = TypeNames.base(of: String(first.dropFirst("_LayoutRoot<".count).dropLast()))
            if Self.stacks[layoutName] != nil { return .passThrough }
            // SwiftUI's own layouts (navigation bar items and the like) are not the app's.
            if raw.typeName.contains("_LayoutRoot<SwiftUI.") || raw.typeName.contains("_LayoutRoot<SwiftUICore.") { return .passThrough }
            var info = NodeInfo()
            let spacing = Self.firstValuePart(raw, named: "spacing", maxDepth: 4)?.number
            info.stack = StackInfo(axis: .grid, name: layoutName, alignment: nil, spacing: spacing)
            return .keep(.stack, layoutName, spacing.map { "spacing \($0.pt)" } ?? "Layout", info, descend: true, isControl: false)
        }

        return .passThrough
    }

    // MARK: - Values ahead of the build

    /// Nodes whose values `classify` and `textInfo` read. The capture encodes them in slices across frames
    /// before it builds the tree; a node left out is encoded during the build, only later.
    static func nodesReadingValues(in roots: [RawDebugNode]) -> [RawDebugNode] {
        var result: [RawDebugNode] = []
        func visit(_ node: RawDebugNode) {
            if valueReadingBases.contains(node.base) || stacks[node.base] != nil
                || (node.base == "_TraitWritingModifier" && node.readable.contains("LayoutPriority"))
                || (node.base == "_VariadicView.Tree" && node.readable.contains("_LayoutRoot<")) {
                result.append(node)
            }
            node.children.forEach(visit)
        }
        roots.forEach(visit)
        return result
    }

    private static let valueReadingBases: Set<String> = [
        "StyledTextContentView", "Image", "AsyncImage", "Resolved", "_ShapeView", "Color", "Spacer", "ScrollView",
        "_PaddingLayout", "_FrameLayout", "_FlexFrameLayout", "_FixedSizeLayout", "_AspectRatioLayout", "_OffsetEffect",
        "_SafeAreaRegionsIgnoringLayout", "_SafeAreaIgnoringLayout", "_BackgroundStyleModifier", "_BackgroundModifier",
        "_BackgroundShapeModifier", "_ClipEffect", "_ShadowEffect",
    ]

    /// Encodes what the build will read from `node`, the same way it reads it.
    static func prepareValues(of node: RawDebugNode) {
        switch node.base {
        case "StyledTextContentView":
            _ = firstValuePart(node, named: "string", maxDepth: 12)
            _ = firstValuePart(node, named: "entries", maxDepth: 12)
        case "Image", "AsyncImage":
            _ = firstValuePart(node, named: "name", maxDepth: 12)
            _ = firstValuePart(node, named: "location", maxDepth: 12)
        case "Resolved":
            _ = firstValuePart(node, named: "unrotatedPixelSize", maxDepth: 12)
            _ = firstValuePart(node, named: "scale", maxDepth: 12)
        case "_BackgroundStyleModifier", "_BackgroundModifier", "_BackgroundShapeModifier":
            _ = valuePart(node, "style")
        case "_ShapeView":
            _ = valuePart(node, "style")
            _ = firstValuePart(node, named: "cornerSize", maxDepth: 12)
        case "_ClipEffect":
            _ = firstValuePart(node, named: "cornerSize", maxDepth: 12)
        case "Spacer":
            _ = valuePart(node, "minLength")
        case "ScrollView":
            _ = firstValuePart(node, named: "axes", maxDepth: 12)
        case "_VariadicView.Tree":
            _ = firstValuePart(node, named: "spacing", maxDepth: 4)
        case _ where stacks[node.base] != nil:
            _ = stackLayoutValue(node, "spacing")
            _ = stackLayoutValue(node, "alignment")
        default:
            _ = node.value
        }
    }

    // MARK: - Checking the parts (diagnostics)

    private enum PartLookup {
        case path([String]), first(String, Int), stack(String)
    }

    private static func partLookups(for base: String) -> [PartLookup] {
        switch base {
        case "StyledTextContentView": [.first("string", 12), .first("entries", 12)]
        case "Image", "AsyncImage": [.first("name", 12), .first("systemSymbol", 12), .first("location", 12)]
        case "Resolved": [.first("unrotatedPixelSize", 12), .first("scale", 12)]
        case "_BackgroundStyleModifier", "_BackgroundModifier", "_BackgroundShapeModifier": [.path(["style"])]
        case "_ShapeView": [.path(["style"]), .first("cornerSize", 12)]
        case "_ClipEffect": [.first("cornerSize", 12)]
        case "Spacer": [.path(["minLength"])]
        case "ScrollView": [.first("axes", 12)]
        case "Text": [.first("verbatim", 12)]
        case "_VariadicView.Tree": [.first("spacing", 4)]
        case _ where stacks[base] != nil: [.stack("spacing"), .stack("alignment")]
        default: []
        }
    }

    /// Every lookup the build makes on a part of a value, compared with the same lookup on the whole encoded
    /// value: one line per difference, `nil` when the data could not be read.
    static func partLookupMismatches(of host: UIView) -> [String]? {
        var result: [String]?
        SwiftUIGraphReader.inUpdate(of: host) { readDebugData in
            let data = readDebugData()
            guard let parts = ViewDebugReader.trees(data, host: host), let wholes = ViewDebugReader.trees(data, host: host) else { return }
            var partNodes: [RawDebugNode] = [], wholeNodes: [RawDebugNode] = []
            parts.forEach { $0.forEach { partNodes.append($0) } }
            wholes.forEach { $0.forEach { wholeNodes.append($0) } }
            var lines: [String] = []
            func json(_ a: DebugAttribute?) -> String {
                a.flatMap { try? JSONSerialization.data(withJSONObject: $0.raw, options: [.sortedKeys]) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
            }
            for (part, whole) in zip(partNodes, wholeNodes) {
                for lookup in partLookups(for: part.base) {
                    let a: DebugAttribute?, b: DebugAttribute?
                    switch lookup {
                    case let .path(path):
                        a = valuePart(part, path); b = whole.value?.at(path)
                    case let .first(name, depth):
                        a = firstValuePart(part, named: name, maxDepth: depth); b = whole.value?.first(named: name, maxDepth: depth)
                    case let .stack(name):
                        a = stackLayoutValue(part, name)
                        let value = whole.value
                        b = (value?.at("_tree", "root") ?? value?["root"] ?? value)?.first(named: name, maxDepth: 3)
                    }
                    let (x, y) = (json(a), json(b))
                    if x != y { lines.append("\(part.readable.prefix(80)) \(lookup): part \(x.prefix(300)) whole \(y.prefix(300))") }
                }
            }
            result = lines
        }
        return result
    }

    // MARK: - Parts of values
    //
    // A container's value holds its whole content, which makes it the most expensive value to encode. The facts
    // read from it sit near the top, so only those parts are encoded (see `RawDebugNode.valuePart`).

    static func valuePart(_ raw: RawDebugNode, _ path: String...) -> DebugAttribute? {
        valuePart(raw, path)
    }

    static func valuePart(_ raw: RawDebugNode, _ path: [String]) -> DebugAttribute? {
        raw.valuePart(path) ?? raw.value?.at(path)
    }

    static func firstValuePart(_ raw: RawDebugNode, named name: String, maxDepth: Int) -> DebugAttribute? {
        raw.firstValuePart(named: name, maxDepth: maxDepth) ?? raw.value?.first(named: name, maxDepth: maxDepth)
    }

    /// `name` in a stack's layout: `_tree.root` of a `VStack`, `root`, or the value itself (`LazyVStack`).
    static func stackLayoutValue(_ raw: RawDebugNode, _ name: String) -> DebugAttribute? {
        switch raw.valuePart(["_tree", "root"]) {
        case let .some(.some(root)): return root.first(named: name, maxDepth: 3)
        case .some(.none):
            switch raw.valuePart(["root"]) {
            case let .some(.some(root)): return root.first(named: name, maxDepth: 3)
            case .some(.none): return firstValuePart(raw, named: name, maxDepth: 3)
            case .none: break
            }
        case .none: break
        }
        let value = raw.value
        return (value?.at("_tree", "root") ?? value?["root"] ?? value)?.first(named: name, maxDepth: 3)
    }

    /// `LayoutInspectorAnchor`, `Optional<LayoutInspectorAnchor>`, `PlatformViewRepresentableAdaptor<LayoutInspectorAnchor>`.
    static func isInspectorAnchor(_ readable: String) -> Bool {
        var type = readable
        while true {
            let base = TypeNames.base(of: type)
            if base == LayoutInspectorAnchor.typeName || base.hasSuffix("." + LayoutInspectorAnchor.typeName) { return true }
            guard base == "Optional" || base == "PlatformViewRepresentableAdaptor",
                  let first = TypeNames.genericArguments(of: type).first else { return false }
            type = first
        }
    }

    // MARK: - Text

    private func textInfo(for raw: RawDebugNode, rect: CGRect) -> TextInfo? {
        let styled = findNode(raw, base: "StyledTextContentView")
        let description = styled.flatMap { Self.firstValuePart($0, named: "string", maxDepth: 12) }?.string
        var info: TextInfo
        if let description {
            let runs = TextStyleParser.runs(fromDescription: description)
            let string = runs.map(\.text).joined()
            let primary = runs.max { $0.text.count < $1.text.count } ?? runs.first
            info = TextInfo(string: string)
            info.runCount = runs.count
            if let attrs = primary?.attributes {
                info.font = TextStyleParser.font(fromAttributes: attrs)
                info.colorHex = TextStyleParser.colorHex(fromAttributes: attrs)
                info.alignment = TextStyleParser.alignment(fromAttributes: attrs)
                info.kerning = TextStyleParser.kerning(fromAttributes: attrs)
            }
        } else if let verbatim = Self.firstValuePart(raw, named: "verbatim", maxDepth: 12)?.string {
            info = TextInfo(string: verbatim)
        } else {
            return nil
        }

        // Layout metrics cached by SwiftUI for each size proposal; pick the one matching the final size.
        if let entries = styled.flatMap({ Self.firstValuePart($0, named: "entries", maxDepth: 12) })?.subattributes, !entries.isEmpty {
            let metrics = entries.compactMap { $0[".1"] }
            let best = metrics.min { a, b in
                let sa = a["size"]?.size ?? .zero, sb = b["size"]?.size ?? .zero
                return abs(sa.width - rect.width) + abs(sa.height - rect.height) < abs(sb.width - rect.width) + abs(sb.height - rect.height)
            }
            info.isTruncated = best?["hasTruncatedRanges"]?.bool ?? false
            info.firstBaseline = best?["firstBaseline"]?.number
        }
        if let lh = info.font?.lineHeight, lh > 0 {
            info.lineCount = max(1, Int((rect.height / lh).rounded()))
        }
        return info
    }

    private func findNode(_ raw: RawDebugNode, base: String, depth: Int = 0) -> RawDebugNode? {
        if raw.base == base { return raw }
        guard depth < 24 else { return nil }
        for c in raw.children { if let hit = findNode(c, base: base, depth: depth + 1) { return hit } }
        return nil
    }

    // MARK: - Scroll views

    private static func scrollViews(in host: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        func walk(_ v: UIView) {
            for sub in v.subviews {
                if SwiftUIGraphReader.isHostingView(sub) { continue }
                if let s = sub as? UIScrollView, !(s is UITextView) { result.append(s) }
                walk(sub)
            }
        }
        walk(host)
        let hosting = result.filter { TypeNames.name(of: type(of: $0)).contains("HostingScrollView") }
        return hosting.isEmpty ? result : hosting
    }

    /// Positions below `SystemScrollView` are expressed in the scroll *content* space.
    /// Find the `UIScrollView` that backs this SwiftUI scroll view (closest visible rect).
    private func matchScrollView(for ctx: Context) -> UIScrollView? {
        let target = ctx.space.convert(ctx.rect, to: host)
        var best: (UIScrollView, CGFloat)?
        for scroll in scrollCandidates {
            let visible = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host)
            let frame = scroll.convert(scroll.bounds, to: host)
            guard frame.intersects(target) || frame.contains(target) else { continue }
            let score = abs(visible.minX - target.minX) + abs(visible.width - target.width)
                + abs(visible.minY - target.minY) * 0.5 + abs(visible.height - target.height) * 0.25
            if best == nil || score < best!.1 { best = (scroll, score) }
        }
        if let best {
            scrollCandidates.removeAll { $0 === best.0 }
            return best.0
        }
        return nil
    }

    // MARK: - Formatting

    private func describeStyle(_ attr: DebugAttribute?) -> String? {
        guard let attr else { return nil }
        return describeColor(attr, depth: 0) ?? TypeNames.base(of: attr.readableType)
    }

    /// `Color` values are nested boxes: `ColorBox<OpacityColor>` → `Color` → `ColorBox<AccentColorProvider>`…
    private func describeColor(_ a: DebugAttribute, depth: Int) -> String? {
        guard depth < 10 else { return nil }
        if let s = a.value as? String { return cleanColor(s) }
        if let dict = a.value as? [String: Any], let key = dict.keys.first {
            if key == "color", let rgba = dict[key] as? [NSNumber], rgba.count >= 3 {
                return TextStyleParser.hex(r: rgba[0].doubleValue, g: rgba[1].doubleValue, b: rgba[2].doubleValue,
                                           a: rgba.count > 3 ? rgba[3].doubleValue : 1)
            }
            return key
        }
        let type = a.readableType
        if type.hasSuffix("AccentColorProvider") || type.hasSuffix("AccentColorProvider>") { return "accentColor" }
        if type.contains("Gradient") { return TypeNames.base(of: TypeNames.shortName(of: type)) }
        if type.contains("OpacityColor") {
            let base = a["base"].flatMap { describeColor($0, depth: depth + 1) } ?? "color"
            if let opacity = a["opacity"]?.number { return "\(base) \(Int((opacity * 100).rounded()))%" }
            return base
        }
        for sub in a.subattributes where sub.name != "kind" {
            if let d = describeColor(sub, depth: depth + 1) { return d }
        }
        return nil
    }

    private func cleanColor(_ s: String) -> String {
        if let range = s.range(of: "name = ") {
            let rest = s[range.upperBound...]
            let name = rest.prefix { $0 != ";" && $0 != ">" }.trimmingCharacters(in: .whitespaces)
            return name.hasSuffix("Color") ? String(name.dropLast(5)) : name
        }
        return s.replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "", options: .regularExpression)
    }

    private func paddingCode(_ p: PaddingInfo) -> String {
        guard let d = p.declared else { return "()" }
        let all = Set([d.top, d.leading, d.bottom, d.trailing])
        if p.edges.count == 4, all.count == 1 { return "(\(d.top.pt))" }
        if Set(p.edges) == ["leading", "trailing"] { return "(.horizontal, \(d.leading.pt))" }
        if Set(p.edges) == ["top", "bottom"] { return "(.vertical, \(d.top.pt))" }
        if p.edges.count == 1, let e = p.edges.first {
            let table: [String: CGFloat] = ["top": d.top, "leading": d.leading, "bottom": d.bottom, "trailing": d.trailing]
            let v = table[e] ?? 0
            return "(.\(e), \(v.pt))"
        }
        return "(t \(d.top.pt), l \(d.leading.pt), b \(d.bottom.pt), r \(d.trailing.pt))"
    }

    private func stackDetail(_ s: StackInfo) -> String {
        var parts: [String] = []
        if let spacing = s.spacing { parts.append("spacing \(spacing.pt)") } else if s.axis != .depth { parts.append("spacing auto") }
        if let a = s.alignment, a != "center" { parts.append(".\(a)") }
        return parts.joined(separator: " · ")
    }

    private func alignmentName(horizontal: String, vertical: String) -> String {
        let h = horizontal.lowercased(), v = vertical.lowercased()
        if h == "center" && v == "center" { return "center" }
        if v == "center" { return h }
        if h == "center" { return v }
        return v + h.prefix(1).uppercased() + h.dropFirst()
    }

    private func sortChildren(_ node: InspectorNode) {
        node.children.sort { a, b in
            let ra = a.anchor.rect, rb = b.anchor.rect
            if a.anchor.view !== b.anchor.view { return false }
            if abs(ra.minY - rb.minY) > 0.5 { return ra.minY < rb.minY }
            return ra.minX < rb.minX
        }
        node.children.forEach(sortChildren)
    }
}

#endif
