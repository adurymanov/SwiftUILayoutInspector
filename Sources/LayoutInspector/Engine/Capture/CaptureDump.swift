#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// Everything a capture holds, as text: every node of both trees with all of its values, the lint issues and
/// the component matching log. Two captures of the same screen give the same text, so a change to the capture
/// code can be checked by diffing the dumps taken before and after it. Ids and memory addresses are left out.
enum CaptureDump {
    static func text(for capture: InspectorCapture) -> String {
        var lines: [String] = ["# graph \(capture.isSwiftUIGraphAvailable)"]
        for root in capture.swiftUIRoots { dump(root, indent: 0, into: &lines) }
        lines.append("# uikit")
        dump(capture.uikitRoot, indent: 0, into: &lines)
        lines.append("# lint")
        for issue in capture.lintIssues() {
            lines.append("\(issue.severity.rawValue) \(issue.message) @ \(rect(issue.rect))")
        }
        lines.append("# report")
        lines.append(LayoutReport.text(for: capture))
        return normalized(lines.joined(separator: "\n"))
    }

    /// Writes the dump of every capture the inspector on screen finishes to `LAYOUT_INSPECTOR_DUMP` (a directory).
    static func writeIfRequested(_ capture: InspectorCapture) {
        guard let dir = ProcessInfo.processInfo.environment["LAYOUT_INSPECTOR_DUMP"], !dir.isEmpty else { return }
        counter += 1
        let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "capture-%03d.txt", counter))
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let header = (["# timings"] + LayoutCapture.lastTimings + ["# reconstruction"] + LayoutCapture.lastReconstructionLog)
            .joined(separator: "\n")
        try? (header + "\n" + text(for: capture)).write(to: url, atomically: true, encoding: .utf8)
    }

    private static var counter = 0

    private static func dump(_ node: InspectorNode, indent: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        var line = "\(pad)\(node.kind.rawValue) \(node.title)"
        if let detail = node.detail { line += " | \(detail)" }
        line += " | \(node.typeName) | \(anchor(node.anchor)) | frame \(rect(node.frame))"
        lines.append(line)
        for fact in facts(node.info) { lines.append("\(pad)  - \(fact)") }
        for child in node.children { dump(child, indent: indent + 1, into: &lines) }
    }

    private static func facts(_ info: NodeInfo) -> [String] {
        var f: [String] = []
        if let p = info.padding {
            f.append("padding declared \(p.declared.map(edges) ?? "nil") edges \(p.edges) measured \(edges(p.measured)) "
                     + "inner \(p.inner.map(anchor) ?? "nil") system \(p.isSystem)")
        }
        if let r = info.frameRule { f.append("frameRule \(r.code) flexible \(r.isFlexible)") }
        if let s = info.stack { f.append("stack \(s.axis.rawValue) \(s.name) alignment \(s.alignment ?? "nil") spacing \(num(s.spacing))") }
        if let t = info.text {
            f.append("text \(t.string.debugDescription) font \(t.font.map(font) ?? "nil") color \(t.colorHex ?? "nil") "
                     + "alignment \(t.alignment ?? "nil") lines \(t.lineCount.map(String.init) ?? "nil") truncated \(t.isTruncated) "
                     + "baseline \(num(t.firstBaseline)) kerning \(num(t.kerning)) runs \(t.runCount)")
        }
        if let i = info.image { f.append("image \(i.name) symbol \(i.isSymbol) natural \(i.naturalSize.map(size) ?? "nil")") }
        if let s = info.shapeName { f.append("shape \(s)") }
        if let s = info.fill { f.append("fill \(s)") }
        if let s = info.fixedSize { f.append("fixedSize \(s.horizontal) \(s.vertical)") }
        if let s = info.layoutPriority { f.append("layoutPriority \(s)") }
        if let s = info.spacerMinLength { f.append("spacerMinLength \(num(s))") }
        if let s = info.aspectRatio { f.append("aspectRatio \(num(s.ratio)) \(s.contentMode)") }
        if let s = info.offset { f.append("offset \(size(s))") }
        if !info.decorations.isEmpty { f.append("decorations \(info.decorations)") }
        if info.isInternal { f.append("internal") }
        for (key, value) in info.raw { f.append("raw \(key) = \(value)") }
        if let u = info.uikit {
            var parts = ["uikit \(u.className)"]
            if let x = u.font { parts.append("font \(font(x))") }
            if let x = u.text { parts.append("text \(x.debugDescription)") }
            if let x = u.textColorHex { parts.append("color \(x)") }
            if let x = u.contentInset { parts.append("contentInset \(x)") }
            if let x = u.layoutMargins { parts.append("margins \(x)") }
            if let x = u.intrinsicSize { parts.append("intrinsic \(size(x))") }
            if let x = u.hugging { parts.append("hugging \(x.h) \(x.v)") }
            if let x = u.compression { parts.append("compression \(x.h) \(x.v)") }
            parts.append("autoLayout \(u.usesAutoLayout) ambiguous \(u.hasAmbiguousLayout) app \(u.isAppView)")
            if let x = u.stackSpacing { parts.append("stackSpacing \(num(x))") }
            if let x = u.stackAxis { parts.append("stackAxis \(x.rawValue)") }
            if !u.arrangedSubviews.isEmpty { parts.append("arranged \(u.arrangedSubviews.map(anchor))") }
            f.append(parts.joined(separator: " "))
            for c in u.constraints {
                f.append("constraint \(c.text) \(c.firstAttribute.rawValue)/\(c.secondAttribute.rawValue) "
                         + "\(anchor(c.first)) \(c.second.map(anchor) ?? "nil") \(num(c.constant)) \(c.relation.rawValue) \(c.priority)")
            }
        }
        return f
    }

    private static func anchor(_ a: NodeAnchor) -> String {
        "\(a.view.map { TypeNames.shortClassName($0) } ?? "nil") \(rect(a.rect))"
    }

    private static func font(_ f: FontInfo) -> String {
        "\(f.family)/\(f.postScriptName)/\(num(f.size))/\(f.weight)/\(f.textStyle ?? "nil")/\(num(f.lineHeight))"
    }

    private static func edges(_ e: EdgeValues) -> String { "(\(num(e.top)) \(num(e.leading)) \(num(e.bottom)) \(num(e.trailing)))" }
    private static func size(_ s: CGSize) -> String { "\(num(s.width))x\(num(s.height))" }
    private static func rect(_ r: CGRect) -> String { r.isNull ? "null" : "\(num(r.minX)),\(num(r.minY)) \(size(r.size))" }
    private static func num(_ v: CGFloat?) -> String {
        guard let v else { return "nil" }
        if v.isNaN { return "nan" }
        if v.isInfinite { return v > 0 ? "inf" : "-inf" }
        return String(format: "%.3f", Double(v))
    }

    /// Memory addresses and type-context addresses differ between runs and builds.
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b0x[0-9a-fA-F]{4,}"#, with: "0x_", options: .regularExpression)
            .replacingOccurrences(of: #"\$[0-9a-fA-F]+"#, with: "$_", options: .regularExpression)
    }
}

#endif
