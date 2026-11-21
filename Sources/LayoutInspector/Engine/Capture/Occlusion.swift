#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// What a presentation hides. UIKit keeps the presenting screen in the window under a `fullScreenCover`, a sheet
/// and the like, so a capture of the whole window holds both: without this the markup of the screen below is drawn
/// over the presented one.
struct Occlusion {
    private struct Level {
        weak var view: UIView?
        let isOpaque: Bool
    }

    /// Presented views from the bottom up.
    private let levels: [Level]

    /// `nil` when nothing opaque is presented in `root`'s window.
    init?(root: UIView) {
        guard let window = (root as? UIWindow) ?? root.window, var top = window.rootViewController else { return nil }
        var levels: [Level] = []
        while let presented = top.presentedViewController {
            top = presented
            guard !presented.isBeingDismissed,
                  let view = presented.presentationController?.presentedView ?? presented.viewIfLoaded,
                  view.window === window else { continue }
            levels.append(Level(view: view, isOpaque: Self.isOpaque(view) || presented.viewIfLoaded.map(Self.isOpaque) == true))
        }
        guard levels.contains(where: \.isOpaque) else { return nil }
        self.levels = levels
    }

    /// The boxes, in `space`, of the opaque presented views above `view`: above the presentation it is in, and, for
    /// a view outside every presentation, also above it in the window (a toast added over a cover stays visible).
    func covers(of view: UIView, in space: UIView) -> [CGRect] {
        // The window and the containers a presentation sits in are under nothing.
        if levels.contains(where: { $0.view?.isDescendant(of: view) == true }) { return [] }
        let level = levels.lastIndex { $0.view.map(view.isDescendant(of:)) == true } ?? -1
        return levels[(level + 1)...].compactMap { above in
            guard above.isOpaque, let cover = above.view else { return nil }
            if level < 0, !Self.isBelow(view, cover) { return nil }
            return NodeAnchor(view: cover, rect: cover.bounds).resolve(in: space)
        }
    }

    /// `view` is drawn before `cover`: their branches meet in a common superview, and `view`'s comes first.
    private static func isBelow(_ view: UIView, _ cover: UIView) -> Bool {
        var coverChain: [UIView] = []
        var v: UIView? = cover
        while let current = v { coverChain.append(current); v = current.superview }
        var child: UIView = view
        var parent = view.superview
        while let p = parent {
            if let i = coverChain.firstIndex(where: { $0 === p }), i > 0 {
                let coverBranch = coverChain[i - 1]
                guard let a = p.subviews.firstIndex(where: { $0 === child }),
                      let b = p.subviews.firstIndex(where: { $0 === coverBranch }) else { return true }
                return a < b
            }
            child = p
            parent = p.superview
        }
        return true
    }

    /// `frame` is hidden when the part of it inside `visible` (what its host shows) is covered.
    static func isHidden(_ frame: CGRect, visible: CGRect, by covers: [CGRect]) -> Bool {
        let shown = frame.intersection(visible)
        let box = shown.isNull ? frame : shown
        return covers.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(box) }
    }

    /// A transparent presented view (a custom overlay, a dimmed alert-like screen) hides nothing.
    private static func isOpaque(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0.99, let color = view.backgroundColor else { return false }
        var alpha: CGFloat = 0
        color.resolvedColor(with: view.traitCollection).getWhite(nil, alpha: &alpha)
        return alpha > 0.99
    }
}

#endif
