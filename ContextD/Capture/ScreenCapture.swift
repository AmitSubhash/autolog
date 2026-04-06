import Foundation
import CoreGraphics
import AppKit

/// Captures single-frame screenshots via CoreGraphics.
///
/// Uses `CGDisplayCreateImage` which requires Screen Recording permission.
/// The permission is requested once during onboarding via `CGRequestScreenCaptureAccess()`.
/// After that, we do NOT re-check with `CGPreflightScreenCaptureAccess()` on every
/// launch because macOS 15+ can return stale results after re-codesign. Instead,
/// captures fail gracefully if permission was truly revoked.
final class ScreenCapture: @unchecked Sendable {
    private let logger = DualLogger(category: "ScreenCapture")

    /// Maximum capture width in pixels. 2560 balances OCR readability and perf.
    private let maxWidth: CGFloat = 2560

    /// Capture a screenshot of the main display.
    /// Async: captures off MainActor, then downscales when needed.
    func captureMainDisplay() async throws -> CGImage? {
        let image: CGImage? = try await Task.detached(priority: .userInitiated) {
            CGDisplayCreateImage(CGMainDisplayID())
        }.value

        guard let raw = image else {
            logger.error("CGDisplayCreateImage returned nil (Screen Recording permission may be missing)")
            return nil
        }

        let scaled = downscaleIfNeeded(raw)
        logger.debug("Captured screenshot: \(scaled.width)x\(scaled.height)")
        return scaled
    }

    /// Proportionally downscale an image if it exceeds `maxWidth`.
    private func downscaleIfNeeded(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        guard width > maxWidth else { return image }

        let scale = maxWidth / width
        let newWidth = Int(width * scale)
        let newHeight = Int(CGFloat(image.height) * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            logger.warning("Failed to create downscale context, returning original image")
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let scaled = context.makeImage() else {
            logger.warning("Failed to create scaled image, returning original")
            return image
        }
        return scaled
    }
}
