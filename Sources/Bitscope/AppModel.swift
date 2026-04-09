import Foundation
import Combine

/// Top-level view model: coordinates the recorder, player and store, and
/// exposes a small amount of UI state (trusted permission, current mode).
@MainActor
final class AppModel: ObservableObject {
    @Published var isTrusted: Bool = PermissionManager.isTrusted
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var status: String = "Idle"

    /// Called whenever user-visible state (recording/playing) changes so the
    /// menu-bar icon can be refreshed.
    var onStateChange: (() -> Void)?

    let store = RecordingStore()
    private let recorder = EventRecorder()
    private let player = EventPlayer()
    private var permissionTimer: Timer?
    /// Guard against re-prompting. The system Accessibility prompt is shown
    /// at most once per app session; after that users are directed to
    /// System Settings instead.
    private var hasPromptedForPermission = false

    init() {
        startPermissionPolling()
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
            onStateChange?()
        } else {
            status = "Failed to start recording"
        }
    }

    private var pendingSnapshot: [ScreenElement] = []

    private func stopRecording() {
        let (events, duration) = recorder.stop()
        isRecording = false
        let name = Self.timestampName()
        let recording = Recording(name: name,
                                  duration: duration,
                                  events: events,
                                  screenSnapshot: pendingSnapshot)
        pendingSnapshot = []
        store.save(recording)
        status = "Saved \(name) — \(events.count) events"
        onStateChange?()
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
        isPlaying = false
        status = "Playback stopped"
    }

    func delete(_ recording: Recording) {
        store.delete(recording)
        status = "Deleted \(recording.name)"
    }

    func deleteAll() {
        store.deleteAll()
        ClickLogger.shared.clear()
        status = "All recordings deleted"
    }

    private static func timestampName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "Recording \(f.string(from: Date()))"
    }
}
