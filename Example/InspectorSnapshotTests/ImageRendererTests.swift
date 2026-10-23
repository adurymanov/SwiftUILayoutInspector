import XCTest
import SwiftUI
import LayoutInspector

/// Xcode's `RunCodeSnippet` has no window scenes: the content has to be drawn without `drawHierarchy`.
@MainActor
final class ImageRendererTests: XCTestCase {
    func test_windowWithoutScene_drawsContent() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = UIHostingController(rootView: Color.red.ignoresSafeArea())
        window.isHidden = false
        window.layoutIfNeeded()
        XCTAssertNil(window.windowScene)

        let image = InspectorImageRenderer.image(of: window, capture: nil, options: nil, scale: 1)

        let (red, green, blue) = try XCTUnwrap(rgb(of: image, at: CGPoint(x: 100, y: 100)))
        XCTAssertGreaterThan(red, 200)
        XCTAssertLessThan(green, 80)
        XCTAssertLessThan(blue, 80)
    }

    private func rgb(of image: UIImage, at point: CGPoint) -> (UInt8, UInt8, UInt8)? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            let scale = CGFloat(cgImage.width) / image.size.width
            context.draw(cgImage, in: CGRect(
                x: -point.x * scale, y: -(CGFloat(cgImage.height) - point.y * scale - 1),
                width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
            ))
            return true
        }
        return drawn ? (pixel[0], pixel[1], pixel[2]) : nil
    }
}
