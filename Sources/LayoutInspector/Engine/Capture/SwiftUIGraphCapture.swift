#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import SwiftUI
import UIKit

/// Every `_UIHostingView<Content>` (and subclasses: `HostingView`, `CellHostingView`…) gets this for free:
/// `_viewDebugData()` is a public (underscored) SwiftUI API. Going through it instead of the ObjC
/// `makeViewDebugData` lets us encode NaN/∞ values that make SwiftUI's own serialisation fail.
protocol ViewDebugDataProviding: AnyObject {
    func _viewDebugData() -> [_ViewDebug.Data]
}

extension _UIHostingView: ViewDebugDataProviding {}

/// Approach #1 – read SwiftUI's own view graph.
///
/// Every `_UIHostingView` (including `HostingView` inside `NavigationStack`, `CellHostingView` in `List`,
/// toolbar/platter hosts…) implements the ObjC method `makeViewDebugData`, the same entry point Xcode's
/// view debugger uses. It returns `_ViewDebug.serializedData(...)` – JSON with the whole SwiftUI tree:
/// view/modifier types, their *values* (padding insets, frame constraints, stack spacing, resolved text
/// attributes) and the laid-out position/size of each node.
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

    static func debugJSON(of host: UIView) -> [[String: Any]]? {
        guard isHostingView(host), let data = host.perform(selector)?.takeUnretainedValue() as? Data else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return json }
        // SwiftUI's JSON serialisation gives up on very deep trees (`Form`, "Too many nested arrays") and
        // returns `{"error": …}`. Fetch `[_ViewDebug.Data]` ourselves and encode it without JSON.
        guard let provider = host as? ViewDebugDataProviding else { return nil }
        var tree: [[String: Any]]?
        UpdateTrampoline.shared.run(in: host.window) {
            tree = (try? TreeEncoder().encode(provider._viewDebugData())) as? [[String: Any]]
        }
        ComponentReconstruction.log.append("\(TypeNames.shortClassName(host)): JSON serialisation failed, tree encoder \(tree == nil ? "failed" : "ok")")
        return tree
    }

    /// Drops subtrees that are not on screen: cells kept for reuse by lazy stacks, fully transparent views.
    static func pruneHidden(_ node: RawDebugNode) {
        node.children.removeAll { child in
            switch child.base {
            case "HiddenForReuseEffect": return child.value?["isHiddenForReuse"]?.bool == true
            case "OpacityRendererEffect", "_OpacityEffect": return (child.value?["opacity"]?.number ?? 1) < 0.01
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

    struct TrampolineView: View {
        let id: Int
        let work: () -> Void
        var body: some View {
            work()
            return Color.clear
        }
    }

    private var counter = 0

    func run(in window: UIWindow?, _ work: @escaping () -> Void) {
        counter += 1
        var done = false
        let view = TrampolineView(id: counter) {
            guard !done else { return }
            done = true
            work()
        }
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
        if !done { _ = controller?.sizeThatFits(in: CGSize(width: 1, height: 1)) }
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
        var offset: CGPoint = .zero
        var rect: CGRect
        var parentReadable: String = ""
        var insideControl: Bool = false
        var controlBase: String?
        var decorations: [String] = []
        weak var parent: InspectorNode?
    }

    func build(roots: [RawDebugNode]) -> InspectorNode {
        let hostNode = InspectorNode(
            id: nextID(), kind: .host,
            title: TypeNames.shortClassName(host),
            typeName: String(describing: type(of: host)),
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
        if let g = raw.geometry {
            ctx.rect = g.offsetBy(dx: ctx.offset.x, dy: ctx.offset.y)
        }

        let classification = classify(raw, ctx)
        var childCtx = ctx
        childCtx.parentReadable = raw.readable

        switch classification {
        case .skipSubtree:
            return

        case let .decoration(text):
            childCtx.decorations.append(text)

        case let .offset(size):
            childCtx.offset.x += size.width
            childCtx.offset.y += size.height
            let node = makeNode(raw, ctx, kind: .offset, title: ".offset",
                                detail: "x \(size.width.pt) y \(size.height.pt)")
            node.info.offset = size
            childCtx.parent = node
            childCtx.decorations = []

        case .enterScroll:
            if let scroll = matchScrollView(for: ctx) {
                childCtx.space = scroll
                childCtx.offset = .zero
                childCtx.rect = CGRect(origin: .zero, size: scroll.contentSize)
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
            if kind == .padding {
                node.info.padding?.inner = innerAnchor(below: raw, ctx)
                if let inner = node.info.padding?.inner {
                    let outer = node.anchor.rect
                    node.info.padding?.measured = EdgeValues(
                        top: inner.rect.minY - outer.minY, leading: inner.rect.minX - outer.minX,
                        bottom: outer.maxY - inner.rect.maxY, trailing: outer.maxX - inner.rect.maxX
                    )
                }
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
        if info.raw.isEmpty, let value = raw.value {
            value.flatten(into: &info.raw, limit: 24)
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

    /// The first descendant that has its own geometry = the content box inside a padding.
    private func innerAnchor(below raw: RawDebugNode, _ ctx: Context) -> NodeAnchor? {
        var current = raw
        while current.children.count == 1 {
            current = current.children[0]
            if let g = current.geometry {
                return NodeAnchor(view: ctx.space, rect: g.offsetBy(dx: ctx.offset.x, dy: ctx.offset.y))
            }
        }
        // Multiple children (e.g. background + content): the content is the largest box.
        let boxes = current.children.compactMap { firstGeometry(in: $0) }
        if let best = boxes.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return NodeAnchor(view: ctx.space, rect: best.offsetBy(dx: ctx.offset.x, dy: ctx.offset.y))
        }
        return nil
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
        let value = raw.value

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
            value?.flatten(into: &info.raw, limit: 16)
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
            let name = value?.first(named: "name")?.string ?? value?.first(named: "systemSymbol")?.string ?? ""
            let location = value?.first(named: "location")?.string ?? ""
            var natural: CGSize?
            if let resolved = raw.children.first.flatMap({ findNode($0, base: "Resolved") })?.value,
               let px = resolved.first(named: "unrotatedPixelSize")?.size,
               let scale = resolved.first(named: "scale")?.number, scale > 0 {
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
            info.fill = describeStyle(value?["style"])
            if let corner = value?.first(named: "cornerSize")?.size, corner.width > 0 {
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
            info.spacerMinLength = value?["minLength"]?.number
            let detail = info.spacerMinLength.map { "≥\($0.pt)" }
            return .keep(.spacer, "Spacer", detail, info, descend: false, isControl: false)

        case "Divider":
            return .keep(.divider, "Divider", nil, NodeInfo(), descend: false, isControl: false)

        case "ScrollView":
            let axis = value?.first(named: "axes")?.string ?? ""
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
            return .decoration(".background(\(describeStyle(value?["style"]) ?? raw.genericArguments.first.map(TypeNames.base) ?? ""))")
        case "_OverlayModifier", "_OverlayStyleModifier", "_OverlayShapeModifier":
            return .decoration(".overlay(\(raw.genericArguments.first.map(TypeNames.base) ?? ""))")
        case "_ClipEffect":
            let shape = raw.genericArguments.first.map(TypeNames.base) ?? ""
            if let corner = value?.first(named: "cornerSize")?.size, corner.width > 0 {
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
            let root = value?.at("_tree", "root") ?? value?["root"] ?? value
            let spacing = root?.first(named: "spacing", maxDepth: 3)?.number
            var alignment = root?.first(named: "alignment", maxDepth: 3)
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
            let spacing = value?.first(named: "spacing", maxDepth: 4)?.number
            info.stack = StackInfo(axis: .grid, name: layoutName, alignment: nil, spacing: spacing)
            return .keep(.stack, layoutName, spacing.map { "spacing \($0.pt)" } ?? "Layout", info, descend: true, isControl: false)
        }

        return .passThrough
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
        let styled = findNode(raw, base: "StyledTextContentView")?.value
        let description = styled?.first(named: "string")?.string
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
        } else if let verbatim = raw.value?.first(named: "verbatim")?.string {
            info = TextInfo(string: verbatim)
        } else {
            return nil
        }

        // Layout metrics cached by SwiftUI for each size proposal; pick the one matching the final size.
        if let entries = styled?.first(named: "entries")?.subattributes, !entries.isEmpty {
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
        let hosting = result.filter { String(describing: type(of: $0)).contains("HostingScrollView") }
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
