#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

public struct LintIssue: Identifiable {
    public enum Severity: String { case error, warning }
    public let id: Int
    public let severity: Severity
    public let message: String
    public let nodeID: Int
    public let rect: CGRect
}

/// Approach #3 – automatic checks on top of the captured tree (design-system linting).
enum LayoutLint {
    static func run(on capture: InspectorCapture, rules: LayoutInspector.LintRules, bounds: CGRect) -> [LintIssue] {
        var issues: [LintIssue] = []
        func add(_ s: LintIssue.Severity, _ msg: String, _ node: InspectorNode, rect: CGRect? = nil) {
            issues.append(LintIssue(id: issues.count + 1, severity: s, message: msg, nodeID: node.id, rect: rect ?? node.frame))
        }
        func offGrid(_ v: CGFloat) -> Bool {
            guard rules.grid > 0, v > 0.5 else { return false }
            let r = v / rules.grid
            return abs(r - r.rounded()) > 0.01
        }

        for node in capture.swiftUINodes where node.isVisible && node.frame.intersects(bounds) {
            switch node.kind {
            case .text:
                guard let text = node.info.text else { break }
                if text.isTruncated { add(.error, "Text truncated: “\(text.string.prefix(24))…”", node) }
                if let font = text.font {
                    if font.textStyle == nil {
                        if !rules.typeScale.isEmpty && !rules.typeScale.contains(font.size) {
                            add(.error, "Font \(font.size.pt)pt is not in the type scale", node)
                        } else if rules.warnOnFixedSizeFonts {
                            add(.warning, "Fixed font \(font.size.pt)pt ignores Dynamic Type", node)
                        }
                    }
                }
            case .padding:
                guard let p = node.info.padding, !p.isSystem else { break }
                let m = p.measured
                let bad = [m.top, m.leading, m.bottom, m.trailing].filter(offGrid)
                if let v = bad.first { add(.warning, "Padding \(v.pt) is off the \(rules.grid.pt)pt grid", node) }
            case .stack:
                guard let stack = node.info.stack, let spacing = stack.spacing, offGrid(spacing) else { break }
                add(.warning, "\(stack.name) spacing \(spacing.pt) is off the \(rules.grid.pt)pt grid", node)
            case .control where node.title == "Button" || node.title == "NavigationLink":
                let f = node.frame
                if f.height < rules.minTapTarget - 0.5 || f.width < rules.minTapTarget - 0.5 {
                    add(.warning, "Tap target \(f.width.pt)×\(f.height.pt) < \(rules.minTapTarget.pt)", node)
                }
            default:
                break
            }

            // Near-miss alignment between siblings of a leading/trailing aligned VStack.
            if node.kind == .stack, let stack = node.info.stack, stack.axis == .vertical,
               let alignment = stack.alignment, alignment == "leading" || alignment == "trailing" {
                let edges = node.children.filter(\.isVisible).map { alignment == "leading" ? $0.frame.minX : $0.frame.maxX }
                if let ref = edges.first {
                    for (child, e) in zip(node.children.filter(\.isVisible), edges) {
                        let d = abs(e - ref)
                        if d > 0.5 && d <= rules.alignmentTolerance {
                            add(.warning, "Almost aligned: off by \(d.pt)pt", child)
                        }
                    }
                }
            }
        }
        // Same message on repeated components (ForEach rows) → one issue with a counter.
        var merged: [LintIssue] = []
        var counts: [String: Int] = [:]
        for issue in issues { counts[issue.message, default: 0] += 1 }
        var seen = Set<String>()
        for issue in issues {
            let count = counts[issue.message] ?? 1
            let message = count > 1 ? "\(issue.message) (×\(count))" : issue.message
            if !seen.contains(issue.message) {
                seen.insert(issue.message)
                merged.append(LintIssue(id: seen.count, severity: issue.severity, message: message, nodeID: issue.nodeID, rect: issue.rect))
            } else {
                // Keep the highlight for every occurrence, numbered like the first one.
                let first = merged.first { $0.message.hasPrefix(issue.message) }!
                merged.append(LintIssue(id: first.id, severity: issue.severity, message: "", nodeID: issue.nodeID, rect: issue.rect))
            }
        }
        return merged
    }
}

#endif
