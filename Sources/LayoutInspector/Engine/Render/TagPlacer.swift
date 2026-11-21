#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// Places small rounded labels next to boxes, avoiding overlaps with already placed labels.
@MainActor
final class TagPlacer {
    enum Placement {
        case aboveLeft, aboveRight, belowLeft, belowRight
        case insideTopLeft, insideTopRight, insideBottomLeft, insideBottomRight
    }

    private var placed: [CGRect] = []
    private let bounds: CGRect
    /// Labels already placed, by text and the box or point they belong to. iOS 26+ tab bars host every item twice
    /// (the copy under the selection lens and the plain one) at the same place: one label is enough, a second one
    /// would only be pushed away from its box.
    private var labelled: [(text: String, anchor: CGRect)] = []

    private func isLabelled(_ text: String, _ anchor: CGRect) -> Bool {
        labelled.contains { $0.text == text && abs($0.anchor.minX - anchor.minX) < 0.5 && abs($0.anchor.minY - anchor.minY) < 0.5
            && abs($0.anchor.width - anchor.width) < 0.5 && abs($0.anchor.height - anchor.height) < 0.5 }
    }

    init(bounds: CGRect) { self.bounds = bounds }

    private func metrics(_ text: String, small: Bool) -> (NSAttributedString, CGSize) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: small ? 8.5 : 9.5, weight: .semibold)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white])
        let size = s.size()
        return (s, CGSize(width: ceil(size.width) + 6, height: ceil(size.height) + 2))
    }

    @discardableResult
    func place(_ text: String, near rect: CGRect, color: UIColor, ctx: CGContext, small: Bool = false,
               swatch: UIColor? = nil, placements: [Placement] = [.aboveLeft, .insideTopLeft, .belowLeft],
               force: Bool = false) -> CGRect? {
        if isLabelled(text, rect) { return nil }
        let (string, base) = metrics(text, small: small)
        let size = CGSize(width: base.width + (swatch == nil ? 0 : base.height), height: base.height)
        var candidates: [CGRect] = placements.map { frame(for: $0, rect: rect, size: size) }
        if force, let first = candidates.first { candidates.append(first) }
        for (i, c) in candidates.enumerated() {
            let r = clamp(c)
            let isLast = i == candidates.count - 1
            if placed.contains(where: { $0.intersects(r.insetBy(dx: 1, dy: 0.5)) }) && !(force && isLast) { continue }
            draw(string, in: r, color: color, swatch: swatch, ctx: ctx)
            placed.append(r)
            labelled.append((text, rect))
            return r
        }
        return nil
    }

    @discardableResult
    func place(_ text: String, center: CGPoint, color: UIColor, ctx: CGContext, small: Bool = true, force: Bool = false) -> CGRect? {
        let point = CGRect(origin: center, size: .zero)
        if isLabelled(text, point) { return nil }
        let (string, size) = metrics(text, small: small)
        let r = clamp(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        if !force, placed.contains(where: { $0.intersects(r) }) { return nil }
        draw(string, in: r, color: color, swatch: nil, ctx: ctx)
        placed.append(r)
        labelled.append((text, point))
        return r
    }

    private func frame(for placement: Placement, rect: CGRect, size: CGSize) -> CGRect {
        let o: CGPoint
        switch placement {
        case .aboveLeft: o = CGPoint(x: rect.minX, y: rect.minY - size.height)
        case .aboveRight: o = CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height)
        case .belowLeft: o = CGPoint(x: rect.minX, y: rect.maxY)
        case .belowRight: o = CGPoint(x: rect.maxX - size.width, y: rect.maxY)
        case .insideTopLeft: o = CGPoint(x: rect.minX + 1, y: rect.minY + 1)
        case .insideTopRight: o = CGPoint(x: rect.maxX - size.width - 1, y: rect.minY + 1)
        case .insideBottomLeft: o = CGPoint(x: rect.minX + 1, y: rect.maxY - size.height - 1)
        case .insideBottomRight: o = CGPoint(x: rect.maxX - size.width - 1, y: rect.maxY - size.height - 1)
        }
        return CGRect(origin: o, size: size)
    }

    private func clamp(_ r: CGRect) -> CGRect {
        var r = r
        if r.maxX > bounds.maxX - 2 { r.origin.x = bounds.maxX - 2 - r.width }
        if r.minX < bounds.minX + 2 { r.origin.x = bounds.minX + 2 }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        return r.integral
    }

    private func draw(_ string: NSAttributedString, in r: CGRect, color: UIColor, swatch: UIColor?, ctx: CGContext) {
        let path = UIBezierPath(roundedRect: r, cornerRadius: 3)
        color.setFill()
        path.fill()
        var textOrigin = CGPoint(x: r.minX + 3, y: r.minY + 1)
        if let swatch {
            let s = CGRect(x: r.minX + 2.5, y: r.minY + 2, width: r.height - 4, height: r.height - 4)
            swatch.setFill()
            UIBezierPath(roundedRect: s, cornerRadius: 1.5).fill()
            UIColor.white.setStroke()
            let border = UIBezierPath(roundedRect: s, cornerRadius: 1.5)
            border.lineWidth = 0.75
            border.stroke()
            textOrigin.x += r.height - 1
        }
        string.draw(at: textOrigin)
    }
}

#endif
