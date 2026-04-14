import Foundation
import Combine

/// Top-level view model: coordinates the recorder, player and store, and
/// exposes a small amount of UI state (trusted permission, current mode).
@MainActor
final class AppModel: ObservableObject {
    @Published var isTrusted: Bool = PermissionManager.isTrusted
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var isWatchingScreenshots = false
    @Published var status: String = "Idle"

    /// Called whenever user-visible state (recording/playing) changes so the
    /// menu-bar icon can be refreshed.
    var onStateChange: (() -> Void)?

    let store = RecordingStore()
    private let recorder = EventRecorder()
    private let player = EventPlayer()
    private let screenshotWatcher = ScreenshotWatcher()
    private var permissionTimer: Timer?
    /// Guard against re-prompting. The system Accessibility prompt is shown
    /// at most once per app session; after that users are directed to
    /// System Settings instead.
    private var hasPromptedForPermission = false

    /// The queryable action index. Opened lazily so a DB failure (disk
    /// full, corrupted file) degrades to "capture still works, index is
    /// disabled" rather than taking down the whole app.
    private let database: Database?
    private let enricher: ActionEnricher
    private let blobStore = BlobStore()
    private let jsonlExporter: JSONLExporter?

    init() {
        let db: Database?
        do {
            db = try Database()
        } catch {
            NSLog("Bitscope: failed to open database: \(error)")
            db = nil
        }
        self.database = db
        self.enricher = ActionEnricher(database: db)
        self.jsonlExporter = db.map { JSONLExporter(database: $0) }
        self.recorder.actionEnricher = enricher
        self.enricher.startSession()
        // Export any actions that accumulated since the last launch.
        jsonlExporter?.exportPending()
        // Enforce retention policy (deletes old blobs + action rows).
        if let db {
            let retention = RetentionManager(database: db, blobStore: blobStore)
            DispatchQueue.global(qos: .utility).async { retention.enforce() }
        }
        startPermissionPolling()
        setupScreenshotWatcher()
    }

    private func setupScreenshotWatcher() {
        screenshotWatcher.onProcessed = { [weak self] fileName in
            Task { @MainActor in
                self?.status = "Processed \(fileName)"
            }
        }
    }

    func toggleScreenshotWatcher() {
        if isWatchingScreenshots {
            stopScreenshotWatcher()
        } else {
            startScreenshotWatcher()
        }
    }

    func startScreenshotWatcher() {
        screenshotWatcher.start()
        isWatchingScreenshots = true
        status = "Watching Desktop for screenshots"
    }

    func stopScreenshotWatcher() {
        screenshotWatcher.stop()
        isWatchingScreenshots = false
        status = "Screenshot watcher stopped"
    }

    /// Called from `AppDelegate.applicationWillTerminate` so the running
    /// session gets a proper end timestamp.
    func shutdown() {
        enricher.endSession()
        screenshotWatcher.stop()
    }

    /// Polls `AXIsProcessTrusted()` so the UI reflects permission being
    /// granted (or revoked) in System Settings without requiring an app
    /// restart. When trust flips to true the "Accessibility permission
    /// needed" banner disappears automatically via SwiftUI re-render — this
    /// is how the popup is "dismissed" on grant.
    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = PermissionManager.isTrusted
                if trusted != self.isTrusted {
                    self.isTrusted = trusted
                    self.status = trusted ? "Accessibility granted" : "Accessibility revoked"
                }
            }
        }
    }

    func requestPermission() {
        // Only trigger the system prompt once per session; afterward, open
        // System Settings directly so the user isn't shown duplicate
        // dialogs.
        if hasPromptedForPermission {
            PermissionManager.openSystemSettings()
            return
        }
        hasPromptedForPermission = true
        _ = PermissionManager.requestTrust()
        isTrusted = PermissionManager.isTrusted
        if !isTrusted {
            PermissionManager.openSystemSettings()
        }
    }

    /// Revokes Accessibility trust via `tccutil reset`, then reopens System
    /// Settings so the user can re-grant. Useful when the TCC database is
    /// in a weird state and permissions appear "stuck".
    func resetPermission() {
        PermissionManager.resetTrust()
        hasPromptedForPermission = false
        isTrusted = PermissionManager.isTrusted
        status = "Accessibility permission reset"
        startPermissionPolling()
        PermissionManager.openSystemSettings()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard isTrusted else {
            status = "Accessibility permission required"
            requestPermission()
            return
        }
        let snapshot = ScreenReader.snapshotFrontmost()
        if recorder.start() {
            isRecording = true
            status = "Recording…"
            pendingSnapshot = snapshot
            // Mint the recording id up front so clicks captured during this
            // session can be linked to the parent row at insert time.
            pendingRecordingID = UUID()
            enricher.beginRecording(id: pendingRecordingID!.uuidString)
            onStateChange?()
        } else {
            status = "Failed to start recording"
        }
    }

    private var pendingSnapshot: [ScreenElement] = []
    private var pendingRecordingID: UUID?

    func stopRecording() {
        let (events, duration) = recorder.stop()
        isRecording = false
        let id = pendingRecordingID ?? UUID()
        pendingRecordingID = nil
        enricher.endRecording()

        let name = Self.timestampName()
        let recording = Recording(id: id,
                                  name: name,
                                  duration: duration,
                                  events: events,
                                  screenSnapshot: pendingSnapshot)
        pendingSnapshot = []
        store.save(recording)

        // Mirror into the queryable index. Non-fatal on failure.
        if let database {
            do {
                try database.insertRecording(
                    id: id.uuidString,
                    sessionID: enricher.currentSessionID,
                    name: name,
                    createdAt: recording.createdAt,
                    duration: duration,
                    jsonPath: store.url(for: recording).path
                )
            } catch {
                NSLog("Bitscope: failed to index recording: \(error)")
            }
        }

        status = "Saved \(name) — \(events.count) events"
        onStateChange?()
        // Flush new actions to JSONL so external tools can consume them
        // without waiting for the next app launch.
        jsonlExporter?.exportPending()
    }

    func play(_ recording: Recording) {
        guard isTrusted else {
            status = "Accessibility permission required"
            requestPermission()
            return
        }
        guard !isPlaying else { return }
        isPlaying = true
        status = "Playing \(recording.name)…"
        onStateChange?()
        player.play(recording) { [weak self] in
            self?.isPlaying = false
            self?.status = "Finished \(recording.name)"
            self?.onStateChange?()
        }
    }

    func stopPlayback() {
        player.stop()
        playbackQueue.removeAll()
        isPlaying = false
        status = "Playback stopped"
        onStateChange?()
    }

    /// Plays every saved recording back-to-back in `createdAt` order
    /// (newest first, matching the list order shown in the UI). Honors
    /// `stopPlayback()` mid-series.
    func playAll() {
        guard isTrusted else {
            status = "Accessibility permission required"
            requestPermission()
            return
        }
        guard !isPlaying else { return }
        guard !store.recordings.isEmpty else {
            status = "No recordings to play"
            return
        }
        playbackQueue = store.recordings
        playNextInQueue()
    }

    private func playNextInQueue() {
        guard !playbackQueue.isEmpty else {
            isPlaying = false
            status = "Finished playing all recordings"
            onStateChange?()
            return
        }
        let next = playbackQueue.removeFirst()
        let remaining = playbackQueue.count
        isPlaying = true
        status = "Playing \(next.name) (\(remaining) remaining)…"
        onStateChange?()
        player.play(next) { [weak self] in
            guard let self else { return }
            // If the user hit Stop mid-series, `playbackQueue` was cleared
            // and `isPlaying` flipped to false — don't keep going.
            if !self.isPlaying { return }
            self.playNextInQueue()
        }
    }

    private var playbackQueue: [Recording] = []

    func delete(_ recording: Recording) {
        store.delete(recording)
        try? database?.deleteRecording(id: recording.id.uuidString)
        status = "Deleted \(recording.name)"
    }

    func deleteAll() {
        store.deleteAll()
        ClickLogger.shared.clear()
        try? database?.deleteAllRecordings()
        blobStore.deleteAll()
        status = "All recordings deleted"
    }

    private static func timestampName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "Recording \(f.string(from: Date()))"
    }
}
