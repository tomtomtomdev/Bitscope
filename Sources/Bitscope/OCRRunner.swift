import Foundation
import Vision
import AppKit

/// Thin wrapper around Vision's text recognition. Returns recognised text
/// with bounding boxes in normalized coordinates (matching the image
/// dimensions).
enum OCRRunner {
    struct Result {
        var text: String
        var boundingBox: CGRect // normalized, origin bottom-left
    }

    /// Runs `VNRecognizeTextRequest` synchronously and returns every
    /// recognised string sorted top-to-bottom, left-to-right. Returns
    /// an empty array on failure rather than throwing so callers don't
    /// need to handle errors for a best-effort fallback.
    static func recognise(in image: CGImage) -> [Result] {
        var results: [Result] = []
        let request = VNRecognizeTextRequest { req, _ in
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            for obs in observations {
                if let candidate = obs.topCandidates(1).first {
                    results.append(Result(
                        text: candidate.string,
                        boundingBox: obs.boundingBox
                    ))
                }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        // Sort top-to-bottom (descending Y since origin is bottom-left),
        // then left-to-right.
        results.sort { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.midX < b.boundingBox.midX
        }
        return results
    }

    /// Convenience: takes an `NSImage`, converts to `CGImage`, and runs
    /// OCR. Returns the recognised lines joined by newline and the raw
    /// results.
    static func recognise(in nsImage: NSImage) -> (text: String, results: [Result]) {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else {
            return ("", [])
        }
        let results = recognise(in: cg)
        let text = results.map(\.text).joined(separator: "\n")
        return (text, results)
    }
}
