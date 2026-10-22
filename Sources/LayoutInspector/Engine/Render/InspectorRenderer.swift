#if LayoutInspectorEngine && os(iOS)
import UIKit

/// What ``InspectorImageRenderer`` draws on top of a view.
public struct InspectorRenderOptions {
    public var mode: LayoutInspector.Mode = .components
    public var showLabels = true
    public var showGrid = false
    public var gridSize: CGFloat = 8
    /// Highlighted node (``InspectorNode/id``). In ``LayoutInspector/Mode/measure`` – the first element.
    public var selectedID: Int?
    /// Second element in ``LayoutInspector/Mode/measure``. `nil` measures to the enclosing container.
    public var measureTargetID: Int?
    public var lintRules = LayoutInspector.LintRules()
    /// Space kept free at the bottom for info cards (lint results, measure hint).
    public var cardBottomInset: CGFloat = 40

    public init(mode: LayoutInspector.Mode = .components) { self.mode = mode }

    init(_ configuration: LayoutInspector.Configuration) {
        mode = configuration.mode
        showLabels = configuration.showsLabels
        showGrid = configuration.showsGrid
        gridSize = configuration.gridSize
        lintRules = configuration.lintRules
    }
}

enum Palette {
    static let component = UIColor(red: 1.00, green: 0.18, blue: 0.58, alpha: 1)
    static let stack = UIColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1)
    static let text = UIColor(red: 0.00, green: 0.67, blue: 0.84, alpha: 1)
    static let image = UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)
    static let shape = UIColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1)
    static let control = UIColor(red: 0.16, green: 0.70, blue: 0.33, alpha: 1)
    static let platform = UIColor(red: 0.19, green: 0.62, blue: 0.62, alpha: 1)
    static let padding = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    static let paddingText = UIColor(red: 0.05, green: 0.38, blue: 0.13, alpha: 1)
    static let gap = UIColor(red: 1.00, green: 0.18, blue: 0.33, alpha: 1)
    static let constraint = UIColor(red: 0.37, green: 0.36, blue: 0.90, alpha: 1)
    static let autoLayout = UIColor(red: 1.00, green: 0.45, blue: 0.00, alpha: 1)
    static let error = UIColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1)
    static let warning = UIColor(red: 0.95, green: 0.65, blue: 0.00, alpha: 1)
    static let select = UIColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1)
    static let neutral = UIColor(white: 0.45, alpha: 1)

    static func color(for kind: NodeKind) -> UIColor {
        switch kind {
        case .component, .customModifier: component
        case .stack: stack
        case .text: text
        case .image: image
        case .shape, .color: shape
        case .control: control
        case .platform, .scroll, .list: platform
        case .padding: padding
        case .frame, .flexFrame, .fixedSize, .aspectRatio, .layoutPriority, .ignoresSafeArea, .offset: constraint
        default: neutral
        }
    }
}

/// Draws a capture into a `CGContext`. Used both by the live overlay and by snapshot tests.
struct InspectorRenderer {
    let capture: InspectorCapture
    let space: UIView
    let bounds: CGRect
    let options: InspectorRenderOptions

    init(capture: InspectorCapture, space: UIView, bounds: CGRect, options: InspectorRenderOptions) {
        self.capture = capture
        self.space = space
        self.bounds = bounds
        self.options = options
    }

    func draw(in ctx: CGContext) {
        let tags = TagPlacer(bounds: bounds)
        if options.showGrid { drawGrid(ctx) }

        if !capture.isSwiftUIGraphAvailable && options.mode != .uikit {
            banner(ctx, "SwiftUI graph is off – call LayoutInspector.bootstrap() at launch. Showing render tree.", color: Palette.warning)
        }

        switch options.mode {
        case .components: drawComponents(ctx, tags)
        case .spacing: drawSpacing(ctx, tags)
        case .typography: drawTypography(ctx, tags)
        case .constraints: drawConstraints(ctx, tags)
        case .uikit: drawUIKit(ctx, tags)
        case .lint: drawLint(ctx, tags)
        case .measure: drawMeasure(ctx, tags)
        }

        if options.mode != .measure, let id = options.selectedID, let node = capture.node(withID: id), node.isVisible {
            drawSelection(ctx, node, tags)
        }
    }

    private var nodes: [InspectorNode] {
        capture.isSwiftUIGraphAvailable ? capture.swiftUINodes.filter { $0.isVisible && $0.frame.intersects(bounds) } : []
    }

    // MARK: - Components

    private func drawComponents(_ ctx: CGContext, _ tags: TagPlacer) {
        let visible = nodes
        if visible.isEmpty { drawRenderTree(ctx, tags, labels: false); return }

        for node in visible {
            let color = Palette.color(for: node.kind)
            switch node.kind {
            case .component:
                stroke(ctx, node.frame, color, width: 1.5)
            case .stack:
                stroke(ctx, node.frame, color, width: 1, dash: [4, 2])
            case .scroll, .list:
                stroke(ctx, node.frame, color, width: 1.2, dash: [6, 3])
            case .text, .image, .shape, .color, .control, .divider:
                fill(ctx, node.frame, color.withAlphaComponent(0.07))
                stroke(ctx, node.frame, color.withAlphaComponent(0.9), width: 0.75)
            case .platform:
                stroke(ctx, node.frame, color, width: 1, dash: [2, 2])
            case .spacer:
                spring(ctx, node.frame, color: Palette.neutral)
            default:
                break
            }
        }
        guard options.showLabels else { return }
        for node in visible where node.kind == .component {
            tags.place("\(node.title) \(node.frame.sizeLabel)", near: node.frame, color: Palette.component, ctx: ctx)
        }
        for node in visible where node.kind == .stack || node.kind == .scroll || node.kind == .list {
            guard node.frame.width > 36, node.frame.height > 18 else { continue }
            tags.place(node.label, near: node.frame, color: Palette.color(for: node.kind), ctx: ctx, small: true,
                       placements: [.insideTopRight, .insideBottomRight, .aboveRight])
        }
        for node in visible where node.kind == .control || node.kind == .platform {
            tags.place(node.title, near: node.frame, color: Palette.color(for: node.kind), ctx: ctx, small: true,
                       placements: [.insideBottomRight, .belowLeft])
        }
    }

    // MARK: - Spacing

    private func drawSpacing(_ ctx: CGContext, _ tags: TagPlacer) {
        let visible = nodes
        for node in visible where node.kind.isContent {
            stroke(ctx, node.frame, Palette.neutral.withAlphaComponent(0.5), width: 0.5)
        }
        // Stack gaps (including the *real* default spacing when `spacing:` is not set).
        for node in visible where node.kind == .stack {
            guard let stack = node.info.stack, stack.axis == .vertical || stack.axis == .horizontal else { continue }
            for gap in gaps(of: node, axis: stack.axis) {
                fill(ctx, gap.rect, Palette.gap.withAlphaComponent(0.28))
                hatch(ctx, gap.rect, Palette.gap.withAlphaComponent(0.5))
                let auto = stack.spacing == nil ? " auto" : ""
                tags.place("\(gap.value.pt)\(auto)", center: CGPoint(x: gap.rect.midX, y: gap.rect.midY), color: Palette.gap, ctx: ctx)
            }
        }
        // Paddings: outer box minus inner box, like browser dev tools.
        for node in visible where node.kind == .padding {
            guard let padding = node.info.padding, let inner = padding.inner?.resolve(in: space) else { continue }
            let outer = node.frame
            let m = padding.measured
            guard !m.isZero else { continue }
            let alpha: CGFloat = padding.isSystem ? 0.18 : 0.35
            let regions: [(CGRect, CGFloat)] = [
                (CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: inner.minY - outer.minY), m.top),
                (CGRect(x: outer.minX, y: inner.maxY, width: outer.width, height: outer.maxY - inner.maxY), m.bottom),
                (CGRect(x: outer.minX, y: inner.minY, width: inner.minX - outer.minX, height: inner.height), m.leading),
                (CGRect(x: inner.maxX, y: inner.minY, width: outer.maxX - inner.maxX, height: inner.height), m.trailing),
            ]
            for (rect, value) in regions where value > 0.25 && rect.width > 0 && rect.height > 0 {
                fill(ctx, rect, Palette.padding.withAlphaComponent(alpha))
                tags.place(value.pt, center: CGPoint(x: rect.midX, y: rect.midY), color: padding.isSystem ? Palette.neutral : Palette.paddingText, ctx: ctx, small: true)
            }
            stroke(ctx, outer, Palette.padding, width: 0.75, dash: [3, 2])
        }
        // UIKit: UIStackView spacing and layout margins of app-provided views.
        for node in capture.uikitNodes where node.isVisible {
            guard let ui = node.info.uikit, ui.isAppView else { continue }
            if let spacing = ui.stackSpacing, let axis = ui.stackAxis {
                let frames = ui.arrangedSubviews.compactMap { $0.resolve(in: space) }.sorted {
                    axis == .vertical ? $0.minY < $1.minY : $0.minX < $1.minX
                }
                for (a, b) in zip(frames, frames.dropFirst()) {
                    let r = axis == .vertical
                        ? CGRect(x: node.frame.minX, y: a.maxY, width: node.frame.width, height: b.minY - a.maxY)
                        : CGRect(x: a.maxX, y: node.frame.minY, width: b.minX - a.maxX, height: node.frame.height)
                    guard r.width > 0.25, r.height > 0.25 else { continue }
                    fill(ctx, r, Palette.gap.withAlphaComponent(0.28))
                    tags.place("\((axis == .vertical ? r.height : r.width).pt) UIStack", center: CGPoint(x: r.midX, y: r.midY), color: Palette.gap, ctx: ctx, small: true)
                }
                _ = spacing
            }
        }
    }

    struct Gap { var rect: CGRect; var value: CGFloat }

    /// Gaps between consecutive children along the stack axis (sweep so overlapping siblings are merged).
    func gaps(of stack: InspectorNode, axis: StackInfo.Axis) -> [Gap] {
        let frames = stack.children.map(\.frame).filter { !$0.isNull }
        guard frames.count > 1 else { return [] }
        let vertical = axis == .vertical
        let sorted = frames.sorted { vertical ? $0.minY < $1.minY : $0.minX < $1.minX }
        var result: [Gap] = []
        var end = vertical ? sorted[0].maxY : sorted[0].maxX
        for f in sorted.dropFirst() {
            let start = vertical ? f.minY : f.minX
            let value = start - end
            if value > 0.25 {
                let rect = vertical
                    ? CGRect(x: stack.frame.minX, y: end, width: stack.frame.width, height: value)
                    : CGRect(x: end, y: stack.frame.minY, width: value, height: stack.frame.height)
                result.append(Gap(rect: rect, value: value))
            }
            end = max(end, vertical ? f.maxY : f.maxX)
        }
        return result
    }

    // MARK: - Typography

    private func drawTypography(_ ctx: CGContext, _ tags: TagPlacer) {
        var texts: [(CGRect, TextInfo?, FontInfo?, String?, Bool)] = []
        for node in nodes where node.kind == .text {
            texts.append((node.frame, node.info.text, node.info.text?.font, node.info.text?.colorHex, false))
        }
        for node in capture.uikitNodes where node.isVisible && node.frame.intersects(bounds) {
            guard let ui = node.info.uikit, let font = ui.font, ui.text?.isEmpty == false else { continue }
            if node.frame.width < 2 || node.frame.height < 2 { continue }
            texts.append((node.frame, nil, font, ui.textColorHex, true))
        }
        for (frame, text, _, _, isUIKit) in texts {
            let truncated = text?.isTruncated ?? false
            let color = truncated ? Palette.error : (isUIKit ? Palette.autoLayout : Palette.text)
            fill(ctx, frame, color.withAlphaComponent(0.10))
            stroke(ctx, frame, color, width: truncated ? 1.5 : 1)
            if let baseline = text?.firstBaseline {
                line(ctx, CGPoint(x: frame.minX, y: frame.minY + baseline), CGPoint(x: frame.maxX, y: frame.minY + baseline),
                     Palette.error.withAlphaComponent(0.8), width: 0.75, dash: [2, 2])
            }
        }
        guard options.showLabels else { return }
        for (frame, text, font, colorHex, isUIKit) in texts {
            guard let font else { continue }
            var label = font.displayName
            if let lines = text?.lineCount, lines > 1 { label += " · \(lines) lines" }
            label += " · lh \(font.lineHeight.pt)"
            if text?.isTruncated == true { label = "TRUNCATED · " + label }
            if isUIKit { label = "UIKit · " + label }
            let swatch = colorHex.flatMap(UIColor.init(hexString:))
            tags.place(label, near: frame, color: text?.isTruncated == true ? Palette.error : (isUIKit ? Palette.autoLayout : Palette.text),
                       ctx: ctx, swatch: swatch, placements: [.belowLeft, .aboveLeft, .insideTopLeft])
        }
    }

    // MARK: - Constraints

    private func drawConstraints(_ ctx: CGContext, _ tags: TagPlacer) {
        let visible = nodes
        for node in visible where node.kind.isContent {
            stroke(ctx, node.frame, Palette.neutral.withAlphaComponent(0.45), width: 0.5)
        }
        // Stack alignment guides.
        for node in visible where node.kind == .stack {
            guard let s = node.info.stack, node.children.count > 1 else { continue }
            let f = node.frame
            let c = Palette.stack.withAlphaComponent(0.55)
            switch (s.axis, s.alignment ?? "center") {
            case (.vertical, "leading"): line(ctx, CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), c, width: 1, dash: [1, 2])
            case (.vertical, "trailing"): line(ctx, CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.maxX, y: f.maxY), c, width: 1, dash: [1, 2])
            case (.vertical, _): line(ctx, CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.midX, y: f.maxY), c, width: 1, dash: [1, 2])
            case (.horizontal, "top"): line(ctx, CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), c, width: 1, dash: [1, 2])
            case (.horizontal, "bottom"): line(ctx, CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY), c, width: 1, dash: [1, 2])
            case (.horizontal, _): line(ctx, CGPoint(x: f.minX, y: f.midY), CGPoint(x: f.maxX, y: f.midY), c, width: 1, dash: [1, 2])
            default: break
            }
        }
        for node in visible {
            let f = node.frame
            switch node.kind {
            case .frame, .flexFrame:
                guard let rule = node.info.frameRule else { continue }
                stroke(ctx, f, Palette.constraint, width: 1, dash: [3, 2])
                if let w = rule.width { dimension(ctx, from: CGPoint(x: f.minX, y: f.maxY + 3), to: CGPoint(x: f.maxX, y: f.maxY + 3), label: "w \(w.pt)", tags: tags) }
                if let h = rule.height { dimension(ctx, from: CGPoint(x: f.maxX + 3, y: f.minY), to: CGPoint(x: f.maxX + 3, y: f.maxY), label: "h \(h.pt)", tags: tags) }
                var notes: [String] = []
                if let v = rule.minWidth { notes.append("minW \(v.pt)") }
                if let v = rule.maxWidth { notes.append("maxW \(v.pt)") }
                if let v = rule.minHeight { notes.append("minH \(v.pt)") }
                if let v = rule.maxHeight { notes.append("maxH \(v.pt)") }
                if let v = rule.idealWidth { notes.append("idealW \(v.pt)") }
                if let v = rule.idealHeight { notes.append("idealH \(v.pt)") }
                if rule.maxWidth == .infinity {
                    arrow(ctx, from: CGPoint(x: f.minX + 2, y: f.midY), to: CGPoint(x: f.maxX - 2, y: f.midY), Palette.constraint.withAlphaComponent(0.6))
                }
                if rule.maxHeight == .infinity {
                    arrow(ctx, from: CGPoint(x: f.midX, y: f.minY + 2), to: CGPoint(x: f.midX, y: f.maxY - 2), Palette.constraint.withAlphaComponent(0.6))
                }
                if !notes.isEmpty {
                    tags.place(notes.joined(separator: " · ") + " → \(f.sizeLabel)", near: f, color: Palette.constraint, ctx: ctx, small: true,
                               placements: [.insideTopLeft, .aboveLeft, .insideBottomLeft])
                }
            case .fixedSize:
                stroke(ctx, f, Palette.constraint, width: 1, dash: [1, 1])
                tags.place("fixedSize\(node.detail == "()" ? "" : " " + (node.info.fixedSize.map { "\($0.horizontal ? "↔" : "")\($0.vertical ? "↕" : "")" } ?? ""))", near: f, color: Palette.constraint, ctx: ctx, small: true, placements: [.insideTopRight, .aboveRight])
            case .layoutPriority:
                tags.place("priority \(node.info.layoutPriority.map { CGFloat($0).pt } ?? "?")", near: f, color: Palette.constraint, ctx: ctx, small: true, placements: [.insideBottomLeft, .belowLeft])
            case .aspectRatio:
                stroke(ctx, f, Palette.constraint, width: 1, dash: [3, 2])
                line(ctx, CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.minY), Palette.constraint.withAlphaComponent(0.5), width: 0.75, dash: [3, 3])
                tags.place("aspect \(node.detail ?? "")", near: f, color: Palette.constraint, ctx: ctx, small: true, placements: [.insideBottomRight])
            case .spacer:
                spring(ctx, f, color: Palette.constraint)
                let length = max(f.width, f.height)
                tags.place("Spacer \(length.pt)\(node.info.spacerMinLength.map { " (≥\($0.pt))" } ?? "")", center: CGPoint(x: f.midX, y: f.midY), color: Palette.constraint, ctx: ctx, small: true)
            case .ignoresSafeArea:
                tags.place("ignoresSafeArea", near: f, color: Palette.constraint, ctx: ctx, small: true, placements: [.insideTopRight])
            default:
                break
            }
        }
        drawAutoLayout(ctx, tags)
    }

    /// Interface Builder style lines for Auto Layout constraints of app-provided UIKit views.
    private func drawAutoLayout(_ ctx: CGContext, _ tags: TagPlacer) {
        for node in capture.uikitNodes where node.isVisible {
            guard let ui = node.info.uikit, ui.isAppView, !ui.constraints.isEmpty else { continue }
            let f = node.frame
            stroke(ctx, f, (ui.hasAmbiguousLayout ? Palette.error : Palette.autoLayout).withAlphaComponent(0.6), width: 0.75)
            for c in ui.constraints {
                let other = c.second?.resolve(in: space)
                let color = c.priority < 1000 ? Palette.autoLayout.withAlphaComponent(0.55) : Palette.autoLayout
                let rel = c.relation == .equal ? "" : (c.relation == .greaterThanOrEqual ? "≥" : "≤")
                switch c.firstAttribute {
                case .leading, .left, .trailing, .right, .leadingMargin, .trailingMargin:
                    guard let o = other else { continue }
                    let isLeading = [.leading, .left, .leadingMargin].contains(c.firstAttribute)
                    let x1 = isLeading ? f.minX : f.maxX
                    let x2 = edgeX(o, c.secondAttribute)
                    guard abs(x2 - x1) > 0.5 else { continue }
                    let y = f.midY
                    line(ctx, CGPoint(x: x1, y: y), CGPoint(x: x2, y: y), color, width: 1)
                    tick(ctx, CGPoint(x: x2, y: y), vertical: true, color)
                    tags.place("\(rel)\(abs(x2 - x1).pt)", center: CGPoint(x: (x1 + x2) / 2, y: y - 6), color: Palette.autoLayout, ctx: ctx, small: true)
                case .top, .bottom, .topMargin, .bottomMargin, .lastBaseline, .firstBaseline:
                    guard let o = other else { continue }
                    let isTop = [.top, .topMargin, .firstBaseline].contains(c.firstAttribute)
                    let y1 = isTop ? f.minY : f.maxY
                    let y2 = edgeY(o, c.secondAttribute)
                    guard abs(y2 - y1) > 0.5 else { continue }
                    let x = f.minX + min(16, f.width / 2)
                    line(ctx, CGPoint(x: x, y: y1), CGPoint(x: x, y: y2), color, width: 1)
                    tick(ctx, CGPoint(x: x, y: y2), vertical: false, color)
                    tags.place("\(rel)\(abs(y2 - y1).pt)", center: CGPoint(x: x + 12, y: (y1 + y2) / 2), color: Palette.autoLayout, ctx: ctx, small: true)
                case .width where c.second == nil:
                    dimension(ctx, from: CGPoint(x: f.minX, y: f.maxY - 3), to: CGPoint(x: f.maxX, y: f.maxY - 3), label: "w \(rel)\(c.constant.pt)", tags: tags, color: Palette.autoLayout)
                case .height where c.second == nil:
                    dimension(ctx, from: CGPoint(x: f.maxX - 3, y: f.minY), to: CGPoint(x: f.maxX - 3, y: f.maxY), label: "h \(rel)\(c.constant.pt)", tags: tags, color: Palette.autoLayout)
                case .centerX, .centerY:
                    guard let o = other else { continue }
                    line(ctx, CGPoint(x: f.midX, y: f.midY), CGPoint(x: o.midX, y: o.midY), color, width: 0.75, dash: [2, 2])
                default:
                    break
                }
            }
        }
    }

    private func edgeX(_ r: CGRect, _ a: NSLayoutConstraint.Attribute) -> CGFloat {
        switch a {
        case .leading, .left, .leadingMargin: r.minX
        case .trailing, .right, .trailingMargin: r.maxX
        case .centerX: r.midX
        default: r.minX
        }
    }

    private func edgeY(_ r: CGRect, _ a: NSLayoutConstraint.Attribute) -> CGFloat {
        switch a {
        case .top, .topMargin, .firstBaseline: r.minY
        case .bottom, .bottomMargin, .lastBaseline: r.maxY
        case .centerY: r.midY
        default: r.minY
        }
    }

    // MARK: - UIKit / render tree

    private static let interestingClasses = [
        "UILabel", "UITextField", "UISwitch", "UIButton", "UIImageView", "UICollectionView", "UITableView",
        "UIStackView", "UISlider", "UIKitTextField", "UpdateCoalescingCollectionView", "HostingScrollView",
        "UIKitPlatformViewHost", "ListCollectionViewCell", "UINavigationBar", "UIKitNavigationBar",
    ]

    private func drawUIKit(_ ctx: CGContext, _ tags: TagPlacer) {
        drawRenderTree(ctx, tags, labels: options.showLabels)
        drawAutoLayout(ctx, tags)
    }

    private func drawRenderTree(_ ctx: CGContext, _ tags: TagPlacer, labels: Bool) {
        let all = capture.uikitNodes.filter { $0.isVisible && $0.frame.intersects(bounds) && $0.frame.width > 0.5 }
        for node in all {
            if node.kind == .renderLayer {
                let color: UIColor = switch node.title {
                case "drawing": Palette.text
                case "image": Palette.image
                case "material": Palette.neutral
                default: Palette.shape
                }
                stroke(ctx, node.frame, color.withAlphaComponent(0.8), width: 0.5, dash: node.title == "fill" ? [2, 1] : nil)
            } else if let ui = node.info.uikit {
                let isHost = SwiftUIGraphReader.isHostingView(node.anchor.view ?? UIView())
                let color = ui.isAppView ? Palette.autoLayout : (isHost ? Palette.component : Palette.neutral.withAlphaComponent(0.6))
                stroke(ctx, node.frame, color, width: ui.isAppView || isHost ? 1 : 0.5)
            }
        }
        guard labels else { return }
        for node in all where node.kind == .uikitView {
            guard let ui = node.info.uikit else { continue }
            let isHost = node.anchor.view.map(SwiftUIGraphReader.isHostingView) ?? false
            let interesting = ui.isAppView || isHost || Self.interestingClasses.contains(ui.className)
            guard interesting, node.frame.width > 24, node.frame.height > 10 else { continue }
            var label = ui.className
            if let font = ui.font, ui.text?.isEmpty == false { label += " · \(font.size.pt)pt \(font.weight)" }
            if let inset = ui.contentInset, inset != .zero { label += " · inset \(inset.top.pt)/\(inset.bottom.pt)" }
            let color = ui.isAppView ? Palette.autoLayout : (isHost ? Palette.component : Palette.neutral)
            tags.place(label, near: node.frame, color: color, ctx: ctx, small: true, placements: [.insideTopLeft, .aboveLeft, .insideBottomLeft])
        }
    }

    // MARK: - Lint

    private func drawLint(_ ctx: CGContext, _ tags: TagPlacer) {
        capture.runLint(rules: options.lintRules, bounds: bounds)
        let issues = capture.issues
        for node in nodes where node.kind.isContent {
            stroke(ctx, node.frame, Palette.neutral.withAlphaComponent(0.35), width: 0.5)
        }
        for issue in issues {
            let color = issue.severity == .error ? Palette.error : Palette.warning
            fill(ctx, issue.rect, color.withAlphaComponent(0.14))
            stroke(ctx, issue.rect, color, width: 1.5)
            tags.place("\(issue.id)", near: issue.rect, color: color, ctx: ctx, placements: [.aboveRight, .insideTopRight, .belowRight], force: true)
        }
        // Issue list card.
        let listed = issues.filter { !$0.message.isEmpty }
        let lines = listed.prefix(9).map { "\($0.id)  \($0.severity == .error ? "✕" : "⚠︎")  \($0.message)" }
        let header = listed.isEmpty ? "✓ No layout issues" : "\(listed.count) issue\(listed.count == 1 ? "" : "s")"
        card(ctx, title: header, lines: Array(lines) + (listed.count > 9 ? ["… +\(listed.count - 9) more"] : []))
    }

    // MARK: - Measure

    private func drawMeasure(_ ctx: CGContext, _ tags: TagPlacer) {
        for node in nodes where node.kind.isContent || node.kind == .component {
            stroke(ctx, node.frame, Palette.neutral.withAlphaComponent(0.4), width: 0.5)
        }
        guard let id = options.selectedID, let a = capture.node(withID: id), a.isVisible else {
            card(ctx, title: "Measure", lines: ["Tap an element, then tap another one", "to see the distance between them."])
            return
        }
        let target = options.measureTargetID.flatMap(capture.node(withID:)) ?? nearestContainer(of: a)
        let A = a.frame
        fill(ctx, A, Palette.select.withAlphaComponent(0.15))
        stroke(ctx, A, Palette.select, width: 1.5)
        tags.place("\(a.title) \(A.sizeLabel)", near: A, color: Palette.select, ctx: ctx, placements: [.aboveLeft, .belowLeft], force: true)
        guard let b = target, b.isVisible else { return }
        let B = b.frame
        stroke(ctx, B, Palette.error, width: 1.2)
        tags.place("\(b.title) \(B.sizeLabel)", near: B, color: Palette.error, ctx: ctx, placements: [.belowRight, .aboveRight, .insideBottomRight], force: true)

        let red = Palette.error
        if B.contains(A) || A.contains(B) {
            let (inner, outer) = B.contains(A) ? (A, B) : (B, A)
            measureLine(ctx, CGPoint(x: outer.minX, y: inner.midY), CGPoint(x: inner.minX, y: inner.midY), red, tags)
            measureLine(ctx, CGPoint(x: inner.maxX, y: inner.midY), CGPoint(x: outer.maxX, y: inner.midY), red, tags)
            measureLine(ctx, CGPoint(x: inner.midX, y: outer.minY), CGPoint(x: inner.midX, y: inner.minY), red, tags)
            measureLine(ctx, CGPoint(x: inner.midX, y: inner.maxY), CGPoint(x: inner.midX, y: outer.maxY), red, tags)
        } else {
            // Horizontal distance
            let y = max(A.minY, B.minY) < min(A.maxY, B.maxY) ? (max(A.minY, B.minY) + min(A.maxY, B.maxY)) / 2 : A.midY
            if A.maxX <= B.minX { measureLine(ctx, CGPoint(x: A.maxX, y: y), CGPoint(x: B.minX, y: y), red, tags) }
            else if B.maxX <= A.minX { measureLine(ctx, CGPoint(x: B.maxX, y: y), CGPoint(x: A.minX, y: y), red, tags) }
            // Vertical distance
            let x = max(A.minX, B.minX) < min(A.maxX, B.maxX) ? (max(A.minX, B.minX) + min(A.maxX, B.maxX)) / 2 : A.midX
            if A.maxY <= B.minY { measureLine(ctx, CGPoint(x: x, y: A.maxY), CGPoint(x: x, y: B.minY), red, tags) }
            else if B.maxY <= A.minY { measureLine(ctx, CGPoint(x: x, y: B.maxY), CGPoint(x: x, y: A.minY), red, tags) }
        }
    }

    private func nearestContainer(of node: InspectorNode) -> InspectorNode? {
        // Prefer the enclosing component (ProfileHeader…), then any container.
        var c = node.parent
        while let n = c {
            if n.kind == .component, n.isVisible, !n.frame.equalTo(node.frame), n.frame.contains(node.frame) { return n }
            c = n.parent
        }
        var p = node.parent
        while let n = p {
            if n.kind != .host, n.isVisible, !n.frame.equalTo(node.frame), n.frame.contains(node.frame),
               n.kind == .component || n.kind == .stack || n.kind == .padding || n.kind == .scroll {
                return n
            }
            p = n.parent
        }
        return nil
    }

    private func measureLine(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ color: UIColor, _ tags: TagPlacer) {
        let d = hypot(b.x - a.x, b.y - a.y)
        guard d > 0.25 else { return }
        line(ctx, a, b, color, width: 1)
        tick(ctx, a, vertical: a.y == b.y, color)
        tick(ctx, b, vertical: a.y == b.y, color)
        tags.place(d.pt, center: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), color: color, ctx: ctx, force: true)
    }

    // MARK: - Selection

    private func drawSelection(_ ctx: CGContext, _ node: InspectorNode, _ tags: TagPlacer) {
        let f = node.frame
        fill(ctx, f, Palette.select.withAlphaComponent(0.18))
        stroke(ctx, f, Palette.select, width: 2)
        if let p = node.info.padding, let inner = p.inner?.resolve(in: space) {
            stroke(ctx, inner, Palette.select, width: 1, dash: [3, 2])
        }
        tags.place("\(node.label) · \(f.sizeLabel)", near: f, color: Palette.select, ctx: ctx, placements: [.aboveLeft, .belowLeft, .insideTopLeft], force: true)
    }

    // MARK: - Primitives

    private func drawGrid(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.systemPink.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(0.5)
        var x = bounds.minX
        while x <= bounds.maxX { ctx.move(to: CGPoint(x: x, y: bounds.minY)); ctx.addLine(to: CGPoint(x: x, y: bounds.maxY)); x += options.gridSize }
        var y = bounds.minY
        while y <= bounds.maxY { ctx.move(to: CGPoint(x: bounds.minX, y: y)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: y)); y += options.gridSize }
        ctx.strokePath()
        ctx.restoreGState()
    }

    func stroke(_ ctx: CGContext, _ rect: CGRect, _ color: UIColor, width: CGFloat, dash: [CGFloat]? = nil) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        let r = rect.width < 1 || rect.height < 1 ? rect : rect.insetBy(dx: width / 2, dy: width / 2)
        ctx.stroke(r)
        ctx.restoreGState()
    }

    func fill(_ ctx: CGContext, _ rect: CGRect, _ color: UIColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    func hatch(_ ctx: CGContext, _ rect: CGRect, _ color: UIColor) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(0.5)
        var x = rect.minX - rect.height
        while x < rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.maxY)); ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.minY)); x += 4
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ color: UIColor, width: CGFloat, dash: [CGFloat]? = nil) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.restoreGState()
    }

    func tick(_ ctx: CGContext, _ p: CGPoint, vertical: Bool, _ color: UIColor) {
        let d: CGFloat = 3
        if vertical { line(ctx, CGPoint(x: p.x, y: p.y - d), CGPoint(x: p.x, y: p.y + d), color, width: 1) }
        else { line(ctx, CGPoint(x: p.x - d, y: p.y), CGPoint(x: p.x + d, y: p.y), color, width: 1) }
    }

    func arrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, _ color: UIColor) {
        line(ctx, a, b, color, width: 1, dash: [3, 2])
        let angle = atan2(b.y - a.y, b.x - a.x)
        for (p, dir) in [(a, angle + .pi), (b, angle)] {
            let l: CGFloat = 5
            line(ctx, p, CGPoint(x: p.x - l * cos(dir - 0.5), y: p.y - l * sin(dir - 0.5)), color, width: 1)
            line(ctx, p, CGPoint(x: p.x - l * cos(dir + 0.5), y: p.y - l * sin(dir + 0.5)), color, width: 1)
        }
    }

    func dimension(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, label: String, tags: TagPlacer, color: UIColor? = nil) {
        let color = color ?? Palette.constraint
        let vertical = a.x == b.x
        line(ctx, a, b, color, width: 1)
        tick(ctx, a, vertical: !vertical, color)
        tick(ctx, b, vertical: !vertical, color)
        tags.place(label, center: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), color: color, ctx: ctx, small: true, force: true)
    }

    func spring(_ ctx: CGContext, _ rect: CGRect, color: UIColor) {
        let horizontal = rect.width >= rect.height
        let length = horizontal ? rect.width : rect.height
        guard length > 4 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        let steps = max(2, Int(length / 6))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let amp: CGFloat = (i == 0 || i == steps) ? 0 : (i % 2 == 0 ? 3 : -3)
            let p = horizontal ? CGPoint(x: rect.minX + t * rect.width, y: rect.midY + amp)
                               : CGPoint(x: rect.midX + amp, y: rect.minY + t * rect.height)
            if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func banner(_ ctx: CGContext, _ text: String, color: UIColor) {
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let size = (text as NSString).boundingRect(with: CGSize(width: bounds.width - 32, height: 100), options: .usesLineFragmentOrigin, attributes: attrs, context: nil).size
        let r = CGRect(x: 12, y: bounds.minY + 60, width: bounds.width - 24, height: size.height + 12)
        UIBezierPath(roundedRect: r, cornerRadius: 8).fill(with: .normal, alpha: 1, color: color)
        (text as NSString).draw(with: r.insetBy(dx: 8, dy: 6), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
    }

    private func card(_ ctx: CGContext, title: String, lines: [String]) {
        let titleFont = UIFont.systemFont(ofSize: 12, weight: .bold)
        let font = UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        let width = bounds.width - 24
        let lineHeight: CGFloat = 15
        let height = 12 + 16 + CGFloat(lines.count) * lineHeight + 8
        let r = CGRect(x: 12, y: bounds.maxY - height - options.cardBottomInset, width: width, height: height)
        UIBezierPath(roundedRect: r, cornerRadius: 12).fill(with: .normal, alpha: 1, color: UIColor(white: 0.08, alpha: 0.88))
        (title as NSString).draw(at: CGPoint(x: r.minX + 12, y: r.minY + 10), withAttributes: [.font: titleFont, .foregroundColor: UIColor.white])
        for (i, l) in lines.enumerated() {
            let p = CGPoint(x: r.minX + 12, y: r.minY + 30 + CGFloat(i) * lineHeight)
            let color: UIColor = l.contains("✕") ? UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1) : (l.contains("⚠︎") ? UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1) : .white)
            (l as NSString).draw(with: CGRect(origin: p, size: CGSize(width: width - 24, height: lineHeight)), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                 attributes: [.font: font, .foregroundColor: color], context: nil)
        }
    }
}

private extension UIBezierPath {
    func fill(with mode: CGBlendMode, alpha: CGFloat, color: UIColor) {
        color.setFill()
        fill(with: mode, alpha: alpha)
    }
}

extension UIColor {
    convenience init?(hexString: String) {
        let parts = hexString.split(separator: " ")
        guard let hex = parts.first, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        var alpha: CGFloat = 1
        if parts.count > 1, let a = Double(parts[1].replacingOccurrences(of: "%", with: "")) { alpha = a / 100 }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
}

#endif
