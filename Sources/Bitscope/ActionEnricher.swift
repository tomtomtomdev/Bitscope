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
