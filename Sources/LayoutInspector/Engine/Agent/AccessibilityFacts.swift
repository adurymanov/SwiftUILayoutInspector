#if LayoutInspectorEngine && !LAYOUT_INSPECTOR_DISABLED && os(iOS)
import UIKit

/// Accessibility identifier and label of a UIKit view, for `capture.json`.
///
/// SwiftUI views are left out on purpose: SwiftUI builds its accessibility tree only while an accessibility client is
/// active, and reading it from inside the app took ~200 ms of the main thread per capture on a small screen. Tools on
/// the Mac read that tree from outside instead (`li` merges it into the capture by frame).
enum AccessibilityFacts {
    static func of(_ view: UIView) -> [String: Any]? {
        var facts: [String: Any] = [:]
        if let id = view.accessibilityIdentifier, !id.isEmpty { facts["identifier"] = id }
        if let label = view.accessibilityLabel, !label.isEmpty { facts["label"] = label }
        return facts.isEmpty ? nil : facts
    }
}

#endif
