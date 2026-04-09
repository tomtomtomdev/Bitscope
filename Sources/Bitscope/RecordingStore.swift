import Foundation
import Combine

/// Persists recordings as individual JSON files inside Application Support.
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    private let directory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        directory = base.appendingPathComponent("Bitscope/Recordings", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory,
                                                includingPropertiesForKeys: nil))
            ?? []
        let loaded: [Recording] = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Recording.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
        recordings = loaded
    }

    func save(_ recording: Recording) {
        let url = directory.appendingPathComponent("\(recording.id.uuidString).json")
        guard let data = try? encoder.encode(recording) else { return }
        try? data.write(to: url, options: .atomic)
        reload()
    }

    func delete(_ recording: Recording) {
        let url = directory.appendingPathComponent("\(recording.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    /// Satisfies the spec's "delete all recordings" requirement.
    func deleteAll() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory,
                                                includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
        reload()
    }
}
