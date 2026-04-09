import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showDeleteAllConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.isTrusted {
                permissionBanner
            }
            recordingsList
            Divider()
            footer
        }
        .frame(width: 420, height: 460)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bitscope").font(.title2).bold()
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Hide the record button entirely when Accessibility isn't
            // granted — clicking it would only surface a permission error.
            if model.isTrusted {
                Button(action: { model.toggleRecording() }) {
                    Label(model.isRecording ? "Stop" : "Record",
                          systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundColor(model.isRecording ? .red : .primary)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isPlaying)
            }
        }
        .padding(12)
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility permission needed").bold()
                Text("Bitscope needs Accessibility access to record and replay input, and to read on-screen information.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Grant Access") { model.requestPermission() }
                    Button("Open System Settings") { PermissionManager.openSystemSettings() }
                    Button("Reset") { model.resetPermission() }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    private var recordingsList: some View {
        Group {
            if model.store.recordings.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No recordings yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.store.recordings) { recording in
                        row(for: recording)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(for recording: Recording) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(recording.name)
                Text("\(recording.events.count) events · \(String(format: "%.1fs", recording.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if model.isPlaying { model.stopPlayback() } else { model.play(recording) }
            } label: {
                Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                model.delete(recording)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
            Button("Reset Permission") {
                model.resetPermission()
            }
            .help("Revokes Accessibility trust for Bitscope via tccutil")
            Spacer()
            Button("Delete All", role: .destructive) {
                showDeleteAllConfirm = true
            }
            .disabled(model.store.recordings.isEmpty)
            .confirmationDialog("Delete all recordings?",
                                isPresented: $showDeleteAllConfirm,
                                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { model.deleteAll() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This cannot be undone.")
            }
        }
        .padding(12)
    }
}
