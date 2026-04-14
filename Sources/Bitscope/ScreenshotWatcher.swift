import Foundation
import AppKit

/// Watches ~/Desktop for new Screenshot*.png files and processes them
/// automatically using `ImageRecognizer`. Results are appended to
/// `~/Desktop/stock-picks.json`.
final class ScreenshotWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var knownFiles: Set<String> = []
    private let queue = DispatchQueue(label: "bitscope.screenshotwatcher", qos: .utility)

    private let desktopURL: URL
    private let outputURL: URL

    var isWatching: Bool { source != nil }

    /// Called when a new screenshot is processed. Passes the file name.
    var onProcessed: ((String) -> Void)?

    init() {
        desktopURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        outputURL = desktopURL.appendingPathComponent("stock-picks.json")
    }

    /// Start watching Desktop for new screenshots.
    func start() {
        guard source == nil else { return }

        // Snapshot current files so we only process NEW ones
        knownFiles = Set(currentScreenshots().map { $0.lastPathComponent })

        fileDescriptor = open(desktopURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            NSLog("ScreenshotWatcher: failed to open Desktop for monitoring")
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: queue
        )

        src.setEventHandler { [weak self] in
            self?.checkForNewScreenshots()
        }

        src.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
            self?.fileDescriptor = -1
        }

        source = src
        src.resume()

        NSLog("ScreenshotWatcher: started monitoring ~/Desktop")
    }

    /// Stop watching.
    func stop() {
        source?.cancel()
        source = nil
        NSLog("ScreenshotWatcher: stopped monitoring")
    }

    // MARK: - Private

    private func currentScreenshots() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("Screenshot") && name.hasSuffix(".png")
        }
    }

    private func checkForNewScreenshots() {
        let current = currentScreenshots()
        let currentNames = Set(current.map { $0.lastPathComponent })
        let newNames = currentNames.subtracting(knownFiles)

        guard !newNames.isEmpty else { return }

        // Small delay to ensure file is fully written
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.processNewFiles(newNames)
        }
    }

    private func processNewFiles(_ names: Set<String>) {
        for name in names.sorted() {
            let url = desktopURL.appendingPathComponent(name)

            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            // Process single image
            guard let result = ImageRecognizer.processImage(at: url) else {
                NSLog("ScreenshotWatcher: failed to process \(name)")
                continue
            }

            // Create stock screener result
            let screenerResult = ImageRecognizer.StockScreenerResult(
                file: name,
                screenerType: detectScreenerType(from: result.fullText),
                stocks: result.stocks
            )

            // Append to JSON file
            appendToOutput(screenerResult)

            knownFiles.insert(name)

            NSLog("ScreenshotWatcher: processed \(name) - \(result.stocks.count) stocks found")

            DispatchQueue.main.async { [weak self] in
                self?.onProcessed?(name)
            }
        }
    }

    private func detectScreenerType(from text: String) -> String? {
        let keywords = [
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
        for keyword in keywords {
            if text.contains(keyword) {
                return keyword
            }
        }
        return nil
    }

    private func appendToOutput(_ result: ImageRecognizer.StockScreenerResult) {
        var existing: [ImageRecognizer.StockScreenerResult] = []

        // Load existing results if file exists
        if let data = try? Data(contentsOf: outputURL),
           let decoded = try? JSONDecoder().decode([ImageRecognizer.StockScreenerResult].self, from: data) {
            existing = decoded
        }

        // Remove any existing entry for same file (re-processing)
        existing.removeAll { $0.file == result.file }

        // Append new result
        existing.append(result)

        // Sort by filename
        existing.sort { $0.file < $1.file }

        // Write back
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(existing) {
            try? data.write(to: outputURL, options: .atomic)
        }
    }
}
