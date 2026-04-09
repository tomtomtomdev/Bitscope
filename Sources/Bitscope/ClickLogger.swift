import Foundation

/// Appends every captured click to a plain-text log file so that clicks
/// recorded during a session survive independently of the JSON recording
/// format. Format is tab-separated and trivial for other tools to parse:
///
///     2026-04-09T10:30:01Z\tleft\t512.0\t337.5
///
/// The log lives alongside recordings in Application Support.
final class ClickLogger {
    static let shared = ClickLogger()

    let logURL: URL
    private let queue = DispatchQueue(label: "bitscope.clicklogger")
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Bitscope", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("clicks.log")
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
    }

    /// Records a single click. `button` is one of "left", "right", "other".
    func logClick(button: String, x: Double, y: Double) {
        let line = "\(formatter.string(from: Date()))\t\(button)\t\(x)\t\(y)\n"
        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            try? self?.handle?.write(contentsOf: data)
        }
    }

    /// Erases the log file. Called when the user deletes all recordings so
    /// the two stores stay in sync.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.handle?.close()
            try? "".data(using: .utf8)?.write(to: self.logURL, options: .atomic)
            self.handle = try? FileHandle(forWritingTo: self.logURL)
            _ = try? self.handle?.seekToEnd()
        }
    }
}
