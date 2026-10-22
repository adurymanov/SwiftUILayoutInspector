#if LayoutInspectorEngine && os(iOS)
import UIKit

/// Approach #2 – walk the UIKit/Core Animation render tree.
///
/// Works without any setup (no `SWIFTUI_VIEW_DEBUG`), in release builds and for any screen.
/// SwiftUI renders most primitives straight into `CALayer`s inside the hosting view
/// (`CGDrawingLayer` for text/vector drawings, plain layers for fills, image layers…),
/// while system controls (`UISwitch`, `UITextField`, `UICollectionView` for `List`) and
/// `UIViewRepresentable`s are real `UIView`s – for those we can read fonts, insets and Auto Layout constraints.
enum UIKitCapture {
    static func capture(root: UIView, excluding: [UIView], nextID: () -> Int) -> InspectorNode {
        let node = makeNode(for: root, nextID: nextID, insideAppView: false)
        walk(root, into: node, excluding: excluding, nextID: nextID, insideAppView: false, insideHost: false, depth: 0)
        return node
    }

    private static func walk(_ view: UIView, into parent: InspectorNode, excluding: [UIView],
                             nextID: () -> Int, insideAppView: Bool, insideHost: Bool, depth: Int) {
        guard depth < 60 else { return }
        let isHost = SwiftUIGraphReader.isHostingView(view)
        let className = TypeNames.shortClassName(view)
        // SwiftUI draws into layers of the hosting view and of its private containers (scroll content etc.).
        if isHost || (insideHost && !className.hasPrefix("UI") && !className.hasPrefix("_UI")) {
            captureLayers(of: view.layer, owner: view, into: parent, nextID: nextID, depth: 0)
        }
        for sub in view.subviews {
            guard !excluding.contains(where: { $0 === sub }), !sub.isHidden, sub.alpha > 0.01 else { continue }
            let isApp = insideAppView || isAppClass(sub)
            let child = makeNode(for: sub, nextID: nextID, insideAppView: isApp)
            parent.add(child)
            walk(sub, into: child, excluding: excluding, nextID: nextID, insideAppView: isApp,
                 insideHost: (insideHost || isHost) && !isApp, depth: depth + 1)
        }
    }

    /// Layers that are not backing a `UIView` – that is where SwiftUI draws text, shapes and fills.
    private static func captureLayers(of layer: CALayer, owner: UIView, into parent: InspectorNode, nextID: () -> Int, depth: Int) {
        guard depth < 30 else { return }
        for sub in layer.sublayers ?? [] where !(sub.delegate is UIView) && !sub.isHidden && sub.opacity > 0.01 {
            let className = TypeNames.shortClassName(sub)
            var title: String?
            if className.contains("CGDrawingLayer") { title = "drawing" }
            else if sub.contents != nil { title = "image" }
            else if sub.backgroundColor != nil { title = "fill" }
            else if sub is CAShapeLayer { title = "shape" }
            else if className.contains("Backdrop") { title = "material" }
            if let title, sub.bounds.width > 0.5, sub.bounds.height > 0.5 {
                var info = NodeInfo()
                if let bg = sub.backgroundColor { info.fill = TextStyleParser.hex(UIColor(cgColor: bg)) }
                if sub.cornerRadius > 0 { info.decorations.append("cornerRadius \(sub.cornerRadius.pt)") }
                let node = InspectorNode(id: nextID(), kind: .renderLayer, title: title, detail: className,
                                         typeName: String(describing: type(of: sub)),
                                         anchor: NodeAnchor(view: owner, rect: owner.layer.convert(sub.bounds, from: sub)),
                                         info: info)
                parent.add(node)
            }
            captureLayers(of: sub, owner: owner, into: parent, nextID: nextID, depth: depth + 1)
        }
    }

    private static func makeNode(for view: UIView, nextID: () -> Int, insideAppView: Bool) -> InspectorNode {
        var ui = UIKitInfo(className: TypeNames.shortClassName(view))
        ui.isAppView = insideAppView
        ui.usesAutoLayout = !view.translatesAutoresizingMaskIntoConstraints
        let intrinsic = view.intrinsicContentSize
        if intrinsic.width != UIView.noIntrinsicMetric || intrinsic.height != UIView.noIntrinsicMetric {
            ui.intrinsicSize = intrinsic
        }
        ui.hugging = (view.contentHuggingPriority(for: .horizontal).rawValue, view.contentHuggingPriority(for: .vertical).rawValue)
        ui.compression = (view.contentCompressionResistancePriority(for: .horizontal).rawValue,
                          view.contentCompressionResistancePriority(for: .vertical).rawValue)
        if view.layoutMargins != .zero, insideAppView { ui.layoutMargins = view.layoutMargins }

        switch view {
        case let label as UILabel:
            ui.font = TextStyleParser.fontInfo(label.font)
            ui.text = label.text
            ui.textColorHex = TextStyleParser.hex(label.textColor)
        case let field as UITextField:
            ui.font = TextStyleParser.fontInfo(field.font)
            ui.text = field.text?.isEmpty == false ? field.text : field.placeholder
            ui.textColorHex = TextStyleParser.hex(field.textColor)
        case let textView as UITextView:
            ui.font = TextStyleParser.fontInfo(textView.font)
            ui.text = textView.text
            ui.contentInset = textView.textContainerInset
        case let scroll as UIScrollView:
            ui.contentInset = scroll.adjustedContentInset
        case let stack as UIStackView:
            ui.stackSpacing = stack.spacing
            ui.stackAxis = stack.axis
            ui.arrangedSubviews = stack.arrangedSubviews.filter { !$0.isHidden }.map { NodeAnchor(view: $0, rect: $0.bounds) }
        default:
            break
        }
        if let button = view as? UIButton, let label = button.titleLabel {
            ui.font = TextStyleParser.fontInfo(label.font)
            ui.text = button.currentTitle ?? button.configuration?.title
        }

        if insideAppView, ui.usesAutoLayout {
            ui.constraints = constraints(of: view)
            ui.hasAmbiguousLayout = view.hasAmbiguousLayout
        }

        var info = NodeInfo()
        info.uikit = ui
        let detail: String? = ui.text.map { "“\($0.prefix(30))”" }
        return InspectorNode(id: nextID(), kind: .uikitView, title: ui.className, detail: detail,
                             typeName: String(describing: type(of: view)),
                             anchor: NodeAnchor(view: view, rect: view.bounds), info: info)
    }

    /// App-provided UIKit: a class from the app's bundle, or the host of an app `UIViewRepresentable`
    /// (`UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<MyApp.RatingStrip>>`).
    private static func isAppClass(_ view: UIView) -> Bool {
        let bundle = Bundle(for: type(of: view))
        if let id = bundle.bundleIdentifier, !id.hasPrefix("com.apple.") { return true }
        let full = String(reflecting: type(of: view))
        guard full.contains("PlatformViewRepresentableAdaptor") || full.contains("PlatformViewControllerRepresentableAdaptor") else { return false }
        let modules = full.matches(of: #/([A-Za-z_][A-Za-z0-9_]*)\./#).map { String($0.output.1) }
        return modules.contains { !TypeNames.systemModules.contains($0) && $0 != "PlatformViewRepresentableAdaptor" }
    }

    /// Constraints that position this view (owned by itself or by its ancestors).
    private static func constraints(of view: UIView) -> [ConstraintInfo] {
        var owners: [UIView] = [view]
        var p = view.superview
        while let s = p, owners.count < 4 { owners.append(s); p = s.superview }

        var result: [ConstraintInfo] = []
        var seen = Set<ObjectIdentifier>()
        for owner in owners {
            for c in owner.constraints where c.isActive && !seen.contains(ObjectIdentifier(c)) {
                guard (c.firstItem as AnyObject?) === view || (c.secondItem as AnyObject?) === view else { continue }
                // Skip system-generated content-size constraints.
                let cls = String(describing: type(of: c))
                if cls.contains("ContentSize") || cls.contains("Autoresizing") { continue }
                seen.insert(ObjectIdentifier(c))
                let flipped = (c.firstItem as AnyObject?) !== view
                let firstAttr = flipped ? c.secondAttribute : c.firstAttribute
                let secondAttr = flipped ? c.firstAttribute : c.secondAttribute
                let otherItem = flipped ? c.firstItem : c.secondItem
                result.append(ConstraintInfo(
                    text: describe(c),
                    firstAttribute: firstAttr,
                    secondAttribute: secondAttr,
                    first: NodeAnchor(view: view, rect: view.bounds),
                    second: anchor(for: otherItem),
                    constant: flipped ? -c.constant : c.constant,
                    relation: c.relation,
                    priority: c.priority.rawValue
                ))
            }
        }
        return result
    }

    private static func anchor(for item: AnyObject?) -> NodeAnchor? {
        if let v = item as? UIView { return NodeAnchor(view: v, rect: v.bounds) }
        if let g = item as? UILayoutGuide, let owner = g.owningView { return NodeAnchor(view: owner, rect: g.layoutFrame) }
        return nil
    }

    static func describe(_ c: NSLayoutConstraint) -> String {
        func name(_ item: AnyObject?) -> String {
            guard let item else { return "" }
            if let g = item as? UILayoutGuide { return g.identifier.isEmpty ? "guide" : g.identifier.replacingOccurrences(of: "UIView", with: "") }
            if let v = item as? UIView {
                if let id = v.accessibilityIdentifier, !id.isEmpty { return id }
                return TypeNames.shortClassName(v)
            }
            return TypeNames.shortClassName(item)
        }
        let rel = c.relation == .equal ? "=" : (c.relation == .greaterThanOrEqual ? "≥" : "≤")
        var rhs = ""
        if c.secondItem != nil {
            rhs = "\(name(c.secondItem)).\(attributeName(c.secondAttribute))"
            if c.multiplier != 1 { rhs += " × \(CGFloat(c.multiplier).pt)" }
            if c.constant != 0 { rhs += (c.constant > 0 ? " + " : " − ") + abs(c.constant).pt }
        } else {
            rhs = c.constant.pt
        }
        let priority = c.priority == .required ? "" : " @\(Int(c.priority.rawValue))"
        return "\(name(c.firstItem)).\(attributeName(c.firstAttribute)) \(rel) \(rhs)\(priority)"
    }

    static func attributeName(_ a: NSLayoutConstraint.Attribute) -> String {
        switch a {
        case .left: "left"; case .right: "right"; case .top: "top"; case .bottom: "bottom"
        case .leading: "leading"; case .trailing: "trailing"; case .width: "width"; case .height: "height"
        case .centerX: "centerX"; case .centerY: "centerY"; case .lastBaseline: "lastBaseline"
        case .firstBaseline: "firstBaseline"; case .leftMargin: "leftMargin"; case .rightMargin: "rightMargin"
        case .topMargin: "topMargin"; case .bottomMargin: "bottomMargin"; case .leadingMargin: "leadingMargin"
        case .trailingMargin: "trailingMargin"; case .centerXWithinMargins: "centerXMargin"
        case .centerYWithinMargins: "centerYMargin"; case .notAnAttribute: "—"
        @unknown default: "?"
        }
    }
}

#endif
