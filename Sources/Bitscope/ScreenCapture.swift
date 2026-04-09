import AppKit
import CoreGraphics

/// Captures a screenshot of the region around a click point. We capture a
/// 400×400 pt patch centred on the click rather than the full window —
/// smaller, faster, fewer privacy concerns.
///
/// On macOS 10.15+ this requires Screen Recording permission. If the app
/// doesn't have it, `CGWindowListCreateImage` returns a nil or
/// fully-transparent image — we detect that and return nil gracefully.
enum ScreenCapture {
    private static let patchSize: CGFloat = 400

    /// Returns a PNG `Data` blob of the region around `point`, or nil if
    /// capture failed (no permission, off-screen, etc.).
    static func capturePatch(around point: CGPoint) -> Data? {
        let half = patchSize / 2
        let rect = CGRect(
            x: point.x - half,
            y: point.y - half,
            width: patchSize,
            height: patchSize
        )

        guard let cgImage = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else { return nil }

        // Detect the "no permission" case: macOS returns a valid image
        // but every pixel is transparent.
        if isBlank(cgImage) { return nil }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// Quick heuristic: sample a handful of pixels and check if they're
    /// all fully transparent. A proper blank-check would scan every pixel
    /// but that's too slow — 5 samples at known offsets is enough.
    private static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return true }
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 4 else { return false }
        let bpr = image.bytesPerRow
        let w = image.width
        let h = image.height
        // Sample 5 points: centre, four quadrants.
        let points = [
            (w / 2, h / 2),
            (w / 4, h / 4),
            (3 * w / 4, h / 4),
            (w / 4, 3 * h / 4),
            (3 * w / 4, 3 * h / 4),
        ]
        for (x, y) in points {
            let offset = y * bpr + x * bpp
            let alpha = ptr[offset + 3] // BGRA/RGBA — alpha is byte 3
            if alpha > 0 { return false }
        }
        return true
    }
}
