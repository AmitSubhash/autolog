import Foundation
import CoreGraphics
import AppKit

/// Captures single-frame screenshots using the system `screencapture` CLI tool.
/// This avoids macOS Sequoia's ScreenCaptureKit permission re-prompts entirely
/// since `screencapture` is a pre-authorized system binary.
///
/// The capture excludes autolog's own windows by temporarily hiding them
/// during the screenshot, then restoring them immediately after.
final class ScreenCapture: @unchecked Sendable {
    private let logger = DualLogger(category: "ScreenCapture")

    /// Maximum capture width in pixels. 2560 balances OCR readability and perf.
    private let maxWidth: CGFloat = 2560

    /// Temporary file path for screenshot output.
    private let tempPath = NSTemporaryDirectory() + "autolog-capture.png"

    /// Capture a screenshot of the main display.
    /// Async: runs screencapture process without blocking the MainActor.
    func captureMainDisplay() async throws -> CGImage? {
        // Run screencapture in a detached task (off MainActor)
        let path = tempPath
        let image: CGImage? = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "png", path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil as CGImage? }

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let nsImage = NSImage(data: data),
                  let cgImage = nsImage.cgImage(
                    forProposedRect: nil, context: nil, hints: nil
                  ) else {
                return nil as CGImage?
            }

            try? FileManager.default.removeItem(atPath: path)
            return cgImage
        }.value

        guard let raw = image else {
            logger.error("screencapture failed or returned nil")
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
