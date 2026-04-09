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
    private let queue = DispatchQueue(label: "bitscope.actionenricher", qos: .utility)

    private(set) var currentSessionID: String?
    private var currentRecordingID: String?

    init(database: Database?) {
        self.database = database
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
        let hit = ScreenReader.hitElement(at: CGPoint(x: x, y: y))
        let frameJSON = hit?.frame.flatMap(Self.encodeFrame)
        let domClassJSON = hit?.domClassList.flatMap(Self.encodeStringArray)

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
            source: hit == nil ? "none" : "ax",
            screenshotHash: nil,
            ocrText: nil
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
