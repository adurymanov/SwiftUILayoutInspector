import SwiftUI
import UIKit
import XCTest
import LayoutInspector

/// Hosts a screen in its own window, waits for its async data and renders it with the inspector overlay.
@MainActor
final class ScreenHarness {
    let window: UIWindow

    init<V: View>(_ view: V) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: NavigationStack { view })
        window.isHidden = false
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Dynamic data: wait until the render tree stops changing and no `ProgressView` is on screen.
    @discardableResult
    func waitUntilLoaded(timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line) async throws -> InspectorCapture {
        do {
            return try await LayoutInspector.captureWhenStable(window, timeout: timeout)
        } catch let error as LayoutInspector.CaptureTimeoutError {
            XCTFail("\(error)", file: file, line: line)
            return capture()
        }
    }

    func capture() -> InspectorCapture {
        LayoutInspector.capture(window)
    }


    func image(_ capture: InspectorCapture?, mode: LayoutInspector.Mode?, configure: (inout InspectorRenderOptions) -> Void = { _ in }) -> UIImage {
        var options: InspectorRenderOptions?
        if let mode {
            var o = InspectorRenderOptions(mode: mode)
            configure(&o)
            options = o
        }
        return InspectorImageRenderer.image(of: window, capture: capture, options: options)
    }
}

/// Builds a labelled contact sheet from several snapshots.
@MainActor
enum ContactSheet {
    static func make(title: String, items: [(String, UIImage)], columns: Int = 4, thumbWidth: CGFloat = 402) -> UIImage {
        guard let first = items.first?.1 else { return UIImage() }
        let aspect = first.size.height / first.size.width
        let thumb = CGSize(width: thumbWidth, height: thumbWidth * aspect)
        let header: CGFloat = 70, caption: CGFloat = 34, gap: CGFloat = 24
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let size = CGSize(width: gap + CGFloat(columns) * (thumb.width + gap),
                          height: header + CGFloat(rows) * (thumb.height + caption + gap) + gap)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            (title as NSString).draw(at: CGPoint(x: gap, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor.black])
            for (i, item) in items.enumerated() {
                let col = i % columns, row = i / columns
                let origin = CGPoint(x: gap + CGFloat(col) * (thumb.width + gap), y: header + CGFloat(row) * (thumb.height + caption + gap))
                (item.0 as NSString).draw(at: CGPoint(x: origin.x, y: origin.y + 2), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor.darkGray])
                let rect = CGRect(origin: CGPoint(x: origin.x, y: origin.y + caption), size: thumb)
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: rect, cornerRadius: 24).addClip()
                item.1.draw(in: rect)
                ctx.cgContext.restoreGState()
                UIColor(white: 0.75, alpha: 1).setStroke()
                UIBezierPath(roundedRect: rect, cornerRadius: 24).stroke()
            }
        }
    }
}
