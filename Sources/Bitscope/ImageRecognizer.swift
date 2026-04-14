import Foundation
import AppKit

/// Batch processor for Desktop screenshots. Scans for `Screenshot*.png` files,
/// runs OCR via `OCRRunner`, and extracts structured stock data as JSON.
enum ImageRecognizer {

    // MARK: - Stock-focused output models

    struct StockScreenerResult: Codable {
        var file: String
        var screenerType: String?
        var stocks: [StockPick]
    }

    struct StockPick: Codable {
        var symbol: String
        var netForeignBuy: String?
        var foreignFlow: String?
        var foreignFlowMA20: String?
        var value: String?
        var rank: Int?
    }

    // MARK: - Raw OCR output models

    struct RecognitionResult: Codable {
        var file: String
        var path: String
        var width: Int
        var height: Int
        var textBlocks: [TextBlock]
        var fullText: String
        var stocks: [StockPick]
    }

    struct TextBlock: Codable {
        var text: String
        var boundingBox: BoundingBox
    }

    struct BoundingBox: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    // MARK: - Stock ticker pattern

    /// Matches Indonesian stock tickers: 4 uppercase letters
    private static let tickerPattern = try! NSRegularExpression(
        pattern: #"^[A-Z]{4}$"#,
        options: []
    )

    /// Common screener type keywords
    private static let screenerKeywords = [
        "Foreign Flow Uptrend",
        "1 Month Net Foreign Flow",
        "Net Foreign Buy",
        "Foreign Flow",
        "Top Broker",
        "Trending",
        "Popular",
        "Valuation",
        "Technical",
        "Dividend",
        "Fundamental",
        "Bandarmology"
    ]

    // MARK: - Public API

    /// Scans Desktop for Screenshot*.png files, extracts stock picks.
    /// Returns JSON string with all results.
    static func processDesktopScreenshots() -> String {
        let desktopURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")

        let files = (try? FileManager.default.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let screenshots = files.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("Screenshot") && name.hasSuffix(".png")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var results: [RecognitionResult] = []

        for url in screenshots {
            if let result = processImage(at: url) {
                results.append(result)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(results),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Returns only extracted stock picks in simplified format.
    static func extractStockPicks() -> String {
        let desktopURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")

        let files = (try? FileManager.default.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let screenshots = files.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("Screenshot") && name.hasSuffix(".png")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var results: [StockScreenerResult] = []

        for url in screenshots {
            if let result = processImage(at: url) {
                let screenerType = detectScreenerType(from: result.fullText)
                results.append(StockScreenerResult(
                    file: url.lastPathComponent,
                    screenerType: screenerType,
                    stocks: result.stocks
                ))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(results),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    // MARK: - Processing

    /// Process a single image file and return recognition result.
    static func processImage(at url: URL) -> RecognitionResult? {
        guard let image = NSImage(contentsOf: url) else {
            NSLog("ImageRecognizer: failed to load \(url.lastPathComponent)")
            return nil
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage else {
            return nil
        }

        let ocrResults = OCRRunner.recognise(in: cgImage)

        let textBlocks = ocrResults.map { result -> TextBlock in
            let box = result.boundingBox
            return TextBlock(
                text: result.text,
                boundingBox: BoundingBox(
                    x: box.origin.x * Double(cgImage.width),
                    y: (1 - box.origin.y - box.height) * Double(cgImage.height),
                    width: box.width * Double(cgImage.width),
                    height: box.height * Double(cgImage.height)
                )
            )
        }

        let fullText = ocrResults.map { $0.text }.joined(separator: "\n")
        let stocks = extractStocks(from: ocrResults, imageHeight: cgImage.height)

        return RecognitionResult(
            file: url.lastPathComponent,
            path: url.path,
            width: cgImage.width,
            height: cgImage.height,
            textBlocks: textBlocks,
            fullText: fullText,
            stocks: stocks
        )
    }

    // MARK: - Stock extraction

    /// Extract stock tickers and associated data from OCR results.
    /// Groups text by Y-coordinate rows and extracts ticker + values.
    private static func extractStocks(
        from ocrResults: [OCRRunner.Result],
        imageHeight: Int
    ) -> [StockPick] {
        // Group by approximate Y position (row)
        var rows: [[OCRRunner.Result]] = []
        let rowThreshold: Double = 0.02 // 2% of image height

        for result in ocrResults {
            let y = result.boundingBox.midY
            var placed = false

            for i in 0..<rows.count {
                if let first = rows[i].first,
                   abs(first.boundingBox.midY - y) < rowThreshold {
                    rows[i].append(result)
                    placed = true
                    break
                }
            }

            if !placed {
                rows.append([result])
            }
        }

        // Sort rows top-to-bottom, items left-to-right
        rows = rows.map { row in
            row.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        }.sorted { ($0.first?.boundingBox.midY ?? 0) > ($1.first?.boundingBox.midY ?? 0) }

        var stocks: [StockPick] = []
        var rank = 1

        for row in rows {
            // Find ticker in row (4 uppercase letters)
            guard let tickerResult = row.first(where: { isTicker($0.text) }) else {
                continue
            }

            let ticker = tickerResult.text

            // Extract numeric values from same row (after ticker position)
            let values = row.filter { result in
                result.boundingBox.midX > tickerResult.boundingBox.midX &&
                isNumericValue(result.text)
            }.map { $0.text }

            let stock = StockPick(
                symbol: ticker,
                netForeignBuy: values.count > 0 ? values[0] : nil,
                foreignFlow: values.count > 2 ? values[2] : nil,
                foreignFlowMA20: values.count > 3 ? values[3] : nil,
                value: values.count > 1 ? values[1] : nil,
                rank: rank
            )

            stocks.append(stock)
            rank += 1
        }

        return stocks
    }

    private static func isTicker(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return tickerPattern.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func isNumericValue(_ text: String) -> Bool {
        // Match patterns like: 65.82, 30.12, (7,131.18 B), 2,484.55 B, etc.
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " B", with: "")
            .replacingOccurrences(of: " T", with: "")
            .replacingOccurrences(of: " M", with: "")
            .trimmingCharacters(in: .whitespaces)

        return Double(cleaned) != nil || cleaned.contains(".")
    }

    private static func detectScreenerType(from text: String) -> String? {
        for keyword in screenerKeywords {
            if text.contains(keyword) {
                return keyword
            }
        }
        return nil
    }

    // MARK: - File output

    /// Process and write results to a JSON file in the same directory.
    static func processAndSave() -> URL? {
        let json = extractStockPicks()

        let desktopURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        let outputURL = desktopURL.appendingPathComponent("stock-picks.json")

        do {
            try json.write(to: outputURL, atomically: true, encoding: .utf8)
            return outputURL
        } catch {
            NSLog("ImageRecognizer: failed to write output: \(error)")
            return nil
        }
    }
}
