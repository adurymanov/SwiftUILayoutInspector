#if LayoutInspectorEngine && os(iOS)
import UIKit

/// SwiftUI resolves every `Text` into an `NSAttributedString` (see `StyledTextContentView` in the debug graph).
/// The debug graph only gives us its `description`, which looks like:
/// ```
/// Hello{
///     NSColor = "UIExtendedSRGBColorSpace 0 0.53 1 1";
///     NSFont = "<UICTFont: 0x…> font-family: \"UICTFontTextStyleBody\"; font-weight: normal; font-style: normal; font-size: 17.00pt";
///     NSParagraphStyle = "Alignment Center, LineSpacing 0, …";
/// }
/// ```
enum TextStyleParser {
    struct Run {
        var text: String
        var attributes: String
    }

    static func runs(fromDescription description: String) -> [Run] {
        var runs: [Run] = []
        var rest = Substring(description)
        while let open = rest.range(of: "{\n") {
            guard let close = rest.range(of: "\n}", range: open.upperBound..<rest.endIndex) else { break }
            let text = String(rest[rest.startIndex..<open.lowerBound])
            let attributes = String(rest[open.upperBound..<close.lowerBound])
            runs.append(Run(text: text, attributes: attributes))
            rest = rest[close.upperBound...]
        }
        if runs.isEmpty, !description.isEmpty { runs.append(Run(text: description, attributes: "")) }
        return runs
    }

    static func font(fromAttributes attributes: String) -> FontInfo? {
        let unescaped = attributes.replacingOccurrences(of: "\\\"", with: "\"")
        guard let family = capture(#"font-family: "([^"]+)""#, in: unescaped),
              let sizeString = capture(#"font-size: ([\d.]+)pt"#, in: unescaped),
              let size = Double(sizeString) else { return nil }
        let cssWeight = capture(#"font-weight: (\w+)"#, in: unescaped) ?? "normal"
        return fontInfo(family: family, size: CGFloat(size), cssWeight: cssWeight)
    }

    static func fontInfo(family: String, size: CGFloat, cssWeight: String) -> FontInfo {
        var textStyle: String?
        var weight = cssWeight == "bold" ? "Bold" : "Regular"
        var font: UIFont?

        if family.hasPrefix("UICTFontTextStyle") {
            var key = String(family.dropFirst("UICTFontTextStyle".count))
            if key.hasPrefix("Emphasized") { key = String(key.dropFirst("Emphasized".count)); weight = "Bold" }
            if key.hasPrefix("Short") { key = String(key.dropFirst("Short".count)) }
            if key.hasPrefix("Tall") { key = String(key.dropFirst("Tall".count)) }
            let (name, style) = textStyleName(key)
            textStyle = name
            if let style {
                let base = UIFont.preferredFont(forTextStyle: style)
                font = base.withSize(size)
                if style == .headline { weight = "Semibold" }
            }
            if key.hasPrefix("Italic") { weight += " Italic" }
        } else if family.hasPrefix(".SF") || family.hasPrefix(".AppleSystem") {
            // ".SFUI-Semibold", ".SFUIDisplay-Bold", ".SFUI-RegularItalic"
            if let dash = family.lastIndex(of: "-") {
                weight = String(family[family.index(after: dash)...])
            }
            font = UIFont.systemFont(ofSize: size, weight: systemWeight(weight))
        } else {
            font = UIFont(name: family, size: size)
            if let traits = font?.fontDescriptor.symbolicTraits, traits.contains(.traitBold) { weight = "Bold" }
        }

        let displayFamily: String
        if textStyle != nil { displayFamily = "SF Pro" }
        else if family.hasPrefix(".SF") || family.hasPrefix(".AppleSystem") { displayFamily = "System" }
        else { displayFamily = family }

        return FontInfo(
            family: displayFamily,
            postScriptName: family,
            size: size,
            weight: weight,
            textStyle: textStyle,
            lineHeight: font?.lineHeight ?? (size * 1.2).rounded()
        )
    }

    static func colorHex(fromAttributes attributes: String) -> String? {
        guard let raw = capture(#"NSColor = "?([^";]+)"?;"#, in: attributes) else { return nil }
        let parts = raw.split(separator: " ")
        guard let space = parts.first else { return raw }
        let numbers = parts.dropFirst().compactMap { Double($0) }
        if space.contains("RGB"), numbers.count >= 3 {
            return hex(r: numbers[0], g: numbers[1], b: numbers[2], a: numbers.count > 3 ? numbers[3] : 1)
        }
        if space.contains("Gray"), numbers.count >= 1 {
            return hex(r: numbers[0], g: numbers[0], b: numbers[0], a: numbers.count > 1 ? numbers[1] : 1)
        }
        return raw
    }

    static func alignment(fromAttributes attributes: String) -> String? {
        capture(#"Alignment (\w+)"#, in: attributes)
    }

    static func kerning(fromAttributes attributes: String) -> CGFloat? {
        capture(#"NSKern = "?([-\d.]+)"#, in: attributes).flatMap(Double.init).map { CGFloat($0) }
    }

    static func hex(r: Double, g: Double, b: Double, a: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", c(r), c(g), c(b))
        return a < 0.999 ? base + String(format: " %d%%", Int((a * 100).rounded())) : base
    }

    static func hex(_ color: UIColor?) -> String? {
        guard let color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return hex(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    static func fontInfo(_ font: UIFont?) -> FontInfo? {
        guard let font else { return nil }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weightValue = (traits?[.weight] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
        let styleAttr = font.fontDescriptor.object(forKey: .textStyle) as? String
        var info = fontInfo(family: styleAttr ?? font.fontName, size: font.pointSize,
                            cssWeight: weightValue >= UIFont.Weight.semibold.rawValue ? "bold" : "normal")
        if styleAttr == nil || !(styleAttr ?? "").hasPrefix("UICTFontTextStyle") {
            info.weight = weightName(UIFont.Weight(weightValue))
            if font.fontName.hasPrefix(".SF") { info.family = "System" }
        }
        info.lineHeight = font.lineHeight
        return info
    }

    // MARK: - Helpers

    private static func textStyleName(_ key: String) -> (String, UIFont.TextStyle?) {
        switch key {
        case "Title0": ("Large Title", .largeTitle)
        case "Title1": ("Title", .title1)
        case "Title2": ("Title 2", .title2)
        case "Title3": ("Title 3", .title3)
        case "Headline": ("Headline", .headline)
        case "Subhead": ("Subheadline", .subheadline)
        case "Body": ("Body", .body)
        case "Callout": ("Callout", .callout)
        case "Footnote": ("Footnote", .footnote)
        case "Caption1": ("Caption", .caption1)
        case "Caption2": ("Caption 2", .caption2)
        default: (key, nil)
        }
    }

    private static func systemWeight(_ name: String) -> UIFont.Weight {
        switch name.lowercased().replacingOccurrences(of: "italic", with: "") {
        case "ultralight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: .regular
        }
    }

    private static func weightName(_ weight: UIFont.Weight) -> String {
        let table: [(UIFont.Weight, String)] = [
            (.ultraLight, "Ultralight"), (.thin, "Thin"), (.light, "Light"), (.regular, "Regular"),
            (.medium, "Medium"), (.semibold, "Semibold"), (.bold, "Bold"), (.heavy, "Heavy"), (.black, "Black"),
        ]
        return table.min { abs($0.0.rawValue - weight.rawValue) < abs($1.0.rawValue - weight.rawValue) }?.1 ?? "Regular"
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

#endif
