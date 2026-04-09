import Foundation
import AppKit

/// Turns raw click events captured by `EventRecorder` into queryable
/// `actions` rows. Runs AX hit-testing on a background queue so the
/// CGEventTap callback stays fast.
///
/// Lifecycle:
/// - `startSession()` once at app launch, `endSession()` at quit.
/// - `beginRecording(...)` / `endRecording()` bracket each recording so
///   enqueued clicks get linked to the correct parent row.
/// - `enqueueClick(...)` is called by the event tap for every
///   `leftDown` / `rightDown` / `otherDown`.
final class ActionEnricher {
    private let database: Database?
    private let blobStore = BlobStore()
    private let queue = DispatchQueue(label: "bitscope.actionenricher", qos: .utility)

    private(set) var currentSessionID: String?
    private var currentRecordingID: String?

    /// Cached deny list — refreshed once per session start.
    private var denyList: Set<String> = []

    init(database: Database?) {
        self.database = database
        self.denyList = database?.denyListBundleIDs() ?? []
    }

    // MARK: - Session

    func startSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.currentSessionID = try? self.database?.startSession()
        }
    }

    func endSession() {
        queue.async { [weak self] in
            guard let self, let id = self.currentSessionID else { return }
            try? self.database?.endSession(id)
            self.currentSessionID = nil
        }
    }

    // MARK: - Recording bracket

    func beginRecording(id: String) {
        queue.async { [weak self] in
            self?.currentRecordingID = id
        }
    }

    func endRecording() {
        queue.async { [weak self] in
            self?.currentRecordingID = nil
        }
    }

    // MARK: - Click enrichment

    /// Called from the CGEventTap callback. Must return quickly.
    func enqueueClick(kind: String, x: Double, y: Double, ts: TimeInterval) {
        queue.async { [weak self] in
            self?.handleClick(kind: kind, x: x, y: y, ts: ts)
        }
    }

    private func handleClick(kind: String, x: Double, y: Double, ts: TimeInterval) {
        guard let database else { return }

        // For screenshot_select actions, find the desktop screenshot and
        // run OCR on it instead of AX hit-testing.
        if kind == "screenshot_select" {
            handleScreenshotSelect(database: database, x: x, y: y, ts: ts)
            return
        }

        let point = CGPoint(x: x, y: y)
        let hit = ScreenReader.hitElement(at: point)

        // Deny-list check: silently skip capture for sensitive apps.
        if let bid = hit?.appBundleID, denyList.contains(bid) { return }

        let frameJSON = hit?.frame.flatMap(Self.encodeFrame)
        let domClassJSON = hit?.domClassList.flatMap(Self.encodeStringArray)

        // Decide whether the AX hit is rich enough or we need the
        // screenshot + OCR fallback. Trigger when there's no hit at
        // all, when the role is AXUnknown, or when the element has
        // no title/value/identifier (meaning AX returned a shell).
        let axIsEmpty = hit == nil
            || hit?.role == nil
            || hit?.role == "AXUnknown"
        let axIsShallow = !axIsEmpty
            && hit?.title == nil
            && hit?.value == nil
            && hit?.identifier == nil

        var screenshotHash: String?
        var ocrText: String?
        var source: String = hit == nil ? "none" : "ax"

        if axIsEmpty || axIsShallow {
            if let pngData = ScreenCapture.capturePatch(around: point) {
                screenshotHash = blobStore.store(png: pngData)

                // Run Vision OCR on the captured patch.
                if let tiff = NSImage(data: pngData).flatMap({ img -> NSBitmapImageRep? in
                    NSBitmapImageRep(data: img.tiffRepresentation ?? Data())
                }), let cg = tiff.cgImage {
                    let results = OCRRunner.recognise(in: cg)
                    let raw = results.map(\.text).joined(separator: "\n")
                    if !raw.isEmpty {
                        // Scrub sensitive patterns before persistence.
                        ocrText = Redactor.redact(raw)
                    }
                }

                source = axIsEmpty ? "ocr" : "hybrid"
            }
        }

        let row = ActionRow(
            recordingID: currentRecordingID,
            sessionID: currentSessionID,
            ts: ts,
            kind: kind,
            x: x,
            y: y,
            appBundleID: hit?.appBundleID,
            appName: hit?.appName,
            windowTitle: hit?.windowTitle,
            axRole: hit?.role,
            axSubrole: hit?.subrole,
            axIdentifier: hit?.identifier,
            axTitle: hit?.title,
            axValue: hit?.value,
            axHelp: hit?.help,
            axDomIdentifier: hit?.domIdentifier,
            axDomClassList: domClassJSON,
            axFrameJSON: frameJSON,
            url: hit?.url,
            source: source,
            screenshotHash: screenshotHash,
            ocrText: ocrText
        )

        do {
            try database.insertAction(row)
        } catch {
            NSLog("ActionEnricher: failed to insert action: \(error)")
        }
    }

    // MARK: - Desktop screenshot OCR

    /// After a ⌘⇧4 drag completes, macOS writes a screenshot file to the
    /// Desktop (or the configured `screencapture` location). This method
    /// polls briefly for the new file, stores it in the blob store, runs
    /// OCR, and writes the result as a `screenshot_select` action.
    private func handleScreenshotSelect(database: Database, x: Double, y: Double, ts: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-3)
        var pngURL: URL?

        // Poll up to 2 seconds for the screenshot file to appear.
        for _ in 0..<20 {
            if let url = Self.latestScreenshot(after: cutoff) {
                pngURL = url
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        var screenshotHash: String?
        var ocrText: String?
        let source: String

        if let url = pngURL, let pngData = try? Data(contentsOf: url) {
            screenshotHash = blobStore.store(png: pngData)

            let (text, _) = OCRRunner.recognise(in: NSImage(data: pngData) ?? NSImage())
            if !text.isEmpty {
                ocrText = Redactor.redact(text)
            }
            source = "ocr"
        } else {
            source = "none"
        }

        let row = ActionRow(
            recordingID: currentRecordingID,
            sessionID: currentSessionID,
            ts: ts,
            kind: "screenshot_select",
            x: x,
            y: y,
            appBundleID: nil,
            appName: nil,
            windowTitle: nil,
            axRole: nil,
            axSubrole: nil,
            axIdentifier: nil,
            axTitle: nil,
            axValue: nil,
            axHelp: nil,
            axDomIdentifier: nil,
            axDomClassList: nil,
            axFrameJSON: nil,
            url: pngURL?.path,
            source: source,
            screenshotHash: screenshotHash,
            ocrText: ocrText
        )

        do {
            try database.insertAction(row)
        } catch {
            NSLog("ActionEnricher: failed to insert screenshot_select action: \(error)")
        }
    }

    /// The macOS screenshot directory (Desktop by default, or the path
    /// set via `defaults write com.apple.screencapture location`).
    static func screenshotDirectory() -> URL {
        let fm = FileManager.default
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "com.apple.screencapture", "location"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if task.terminationStatus == 0, !path.isEmpty,
               fm.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        } catch {}
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    /// Returns the most recent screenshot file created after `cutoff`.
    private static func latestScreenshot(after cutoff: Date) -> URL? {
        let dir = screenshotDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (url: URL, date: Date)?
        for url in contents where url.pathExtension.lowercased() == "png" {
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey]),
                  let created = values.creationDate,
                  created > cutoff else { continue }
            if best == nil || created > best!.date {
                best = (url, created)
            }
        }
        return best?.url
    }

    // MARK: - Desktop screenshot scanner

    /// Scans the screenshot directory for PNG files whose filenames start
    /// with "Screenshot", skips any already in the database (by URL path),
    /// and processes new ones with OCR + blob storage.
    func scanDesktopScreenshots() {
        queue.async { [weak self] in
            guard let self, let database = self.database else { return }
            let known = (try? database.knownScreenshotURLs()) ?? []
            let dir = Self.screenshotDirectory()

            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            let screenshots = contents.filter {
                $0.pathExtension.lowercased() == "png"
                && $0.lastPathComponent.hasPrefix("Screenshot")
                && !known.contains($0.path)
            }

            for url in screenshots {
                guard let pngData = try? Data(contentsOf: url) else { continue }
                let hash = self.blobStore.store(png: pngData)

                let (text, _) = OCRRunner.recognise(in: NSImage(data: pngData) ?? NSImage())
                let ocrText = text.isEmpty ? nil : Redactor.redact(text)

                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()

                let row = ActionRow(
                    recordingID: nil,
                    sessionID: self.currentSessionID,
                    ts: created.timeIntervalSince1970,
                    kind: "screenshot_select",
                    x: nil,
                    y: nil,
                    appBundleID: nil,
                    appName: nil,
                    windowTitle: nil,
                    axRole: nil,
                    axSubrole: nil,
                    axIdentifier: nil,
                    axTitle: nil,
                    axValue: nil,
                    axHelp: nil,
                    axDomIdentifier: nil,
                    axDomClassList: nil,
                    axFrameJSON: nil,
                    url: url.path,
                    source: ocrText != nil ? "ocr" : "none",
                    screenshotHash: hash,
                    ocrText: ocrText
                )

                do {
                    try database.insertAction(row)
                } catch {
                    NSLog("ActionEnricher: failed to insert scanned screenshot: \(error)")
                }
            }
        }
    }

    private static func encodeFrame(_ frame: CGRect) -> String? {
        let dict: [String: Double] = [
            "x": frame.origin.x, "y": frame.origin.y,
            "w": frame.size.width, "h": frame.size.height
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeStringArray(_ strings: [String]) -> String? {
        guard !strings.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: strings)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
