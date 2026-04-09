import Foundation

/// Streams new `actions` rows into daily-bucketed JSONL files under
/// `~/Library/Application Support/Bitscope/export/`. Each line is a
/// self-contained JSON object describing one click with its full AX
/// context — trivially consumable by `jq`, Python, or any agent that
/// reads plain text.
///
/// The exporter is incremental: it tracks the highest exported action ID
/// in the `meta` table so it only writes the delta on each run. Call
/// `exportPending()` on launch and after each recording save.
final class JSONLExporter {
    private let database: Database
    private let exportDir: URL
    private let queue = DispatchQueue(label: "bitscope.jsonl-exporter", qos: .utility)

    private static let metaKey = "jsonl_last_exported_action_id"

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(database: Database) {
        self.database = database
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        exportDir = base.appendingPathComponent("Bitscope/export", isDirectory: true)
        try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
    }

    /// Exports any actions inserted since the last run. Safe to call
    /// repeatedly — a no-op when there's nothing new.
    func exportPending() {
        queue.async { [weak self] in
            self?.runExport()
        }
    }

    private func runExport() {
        let lastID: Int64 = {
            if let raw = database.getMeta(Self.metaKey), let id = Int64(raw) { return id }
            return 0
        }()

        // Page through in 10k batches so we don't load the whole table at
        // once if there's a very large backlog (first run on an old DB).
        var cursor = lastID
        var totalExported = 0

        while true {
            guard let batch = try? database.actionsAfter(id: cursor, limit: 10_000),
                  !batch.isEmpty else { break }

            // Group by calendar day based on the action's wall-clock ts.
            let grouped = Dictionary(grouping: batch) { row -> String in
                let date = Date(timeIntervalSince1970: row.ts)
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                df.timeZone = .current
                return df.string(from: date)
            }

            for (day, rows) in grouped {
                let fileURL = exportDir.appendingPathComponent("actions-\(day).jsonl")
                appendRows(rows, to: fileURL)
            }

            cursor = batch.last!.id
            totalExported += batch.count
        }

        if totalExported > 0 {
            try? database.setMeta(Self.metaKey, String(cursor))
            NSLog("JSONLExporter: exported \(totalExported) action(s), cursor now at \(cursor)")
        }
    }

    private func appendRows(_ rows: [ActionExportRow], to url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()

        for row in rows {
            let obj = jsonObject(for: row)
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                handle.write(data)
                handle.write(Data([0x0A])) // newline
            }
        }
    }

    /// Builds a structured JSON dictionary for one action. Nesting keeps
    /// the top level flat while grouping related fields — downstream
    /// tools can pull `target.identifier` or `app.bundle_id` cleanly.
    private func jsonObject(for row: ActionExportRow) -> [String: Any] {
        var obj: [String: Any] = [
            "id": row.id,
            "ts": row.ts,
            "iso_ts": iso.string(from: Date(timeIntervalSince1970: row.ts)),
            "kind": row.kind,
            "source": row.source,
        ]

        if let x = row.x, let y = row.y {
            obj["x"] = x
            obj["y"] = y
        }
        if let rid = row.recordingID { obj["recording_id"] = rid }
        if let sid = row.sessionID { obj["session_id"] = sid }

        // App context
        var app: [String: Any] = [:]
        if let v = row.appBundleID { app["bundle_id"] = v }
        if let v = row.appName { app["name"] = v }
        if !app.isEmpty { obj["app"] = app }

        if let v = row.windowTitle { obj["window_title"] = v }

        // AX target identity
        var target: [String: Any] = [:]
        if let v = row.axRole { target["role"] = v }
        if let v = row.axSubrole { target["subrole"] = v }
        if let v = row.axIdentifier { target["identifier"] = v }
        if let v = row.axTitle { target["title"] = v }
        if let v = row.axValue { target["value"] = v }
        if let v = row.axHelp { target["help"] = v }
        if let v = row.axDomIdentifier { target["dom_identifier"] = v }
        if let v = row.axDomClassList,
           let data = v.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) {
            target["dom_class_list"] = arr
        }
        if let v = row.axFrameJSON,
           let data = v.data(using: .utf8),
           let frame = try? JSONSerialization.jsonObject(with: data) {
            target["frame"] = frame
        }
        if let v = row.url { target["url"] = v }
        if !target.isEmpty { obj["target"] = target }

        if let v = row.screenshotHash { obj["screenshot_hash"] = v }
        if let v = row.ocrText { obj["ocr_text"] = v }

        return obj
    }
}
