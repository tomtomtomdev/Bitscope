import Foundation
import GRDB

/// GRDB-backed persistence layer for Bitscope's queryable history.
///
/// The database lives at `~/Library/Application Support/Bitscope/bitscope.sqlite`
/// and is the authoritative index over recordings. It exists alongside the
/// per-recording JSON files (for portable replay) and the `clicks.log` file
/// (for lowest-common-denominator interop).
///
/// All writes go through a `DatabaseQueue` and are serialized; reads can be
/// issued from any thread.
final class Database {
    let dbQueue: DatabaseQueue
    let dbURL: URL

    init() throws {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Bitscope", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("bitscope.sqlite")

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Schema migrations

    /// The migrator is append-only. Never edit an existing migration after it
    /// has shipped; add a new one instead. Schema v1 establishes the core
    /// three-table layout: sessions → recordings → actions.
    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial_schema") { db in
            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("started_at", .double).notNull()
                t.column("ended_at", .double)
                t.column("app_bundle_ids", .text) // JSON array
            }

            try db.create(table: "recordings") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                    .references("sessions", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("duration", .double).notNull()
                t.column("json_path", .text).notNull()
            }
            try db.create(indexOn: "recordings", columns: ["created_at"])

            try db.create(table: "actions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recording_id", .text)
                    .references("recordings", onDelete: .cascade)
                t.column("session_id", .text)
                    .references("sessions", onDelete: .setNull)
                t.column("ts", .double).notNull()
                t.column("kind", .text).notNull()
                t.column("x", .double)
                t.column("y", .double)
                t.column("app_bundle_id", .text)
                t.column("app_name", .text)
                t.column("window_title", .text)
                t.column("ax_role", .text)
                t.column("ax_subrole", .text)
                t.column("ax_identifier", .text)
                t.column("ax_title", .text)
                t.column("ax_value", .text)
                t.column("ax_frame_json", .text)
                t.column("url", .text)
                t.column("source", .text).notNull()   // ax | ocr | hybrid
                t.column("screenshot_hash", .text)    // reserved; populated later
                t.column("ocr_text", .text)           // reserved; populated later
            }
            try db.create(indexOn: "actions", columns: ["ts"])
            try db.create(indexOn: "actions", columns: ["app_bundle_id", "ts"])
            try db.create(indexOn: "actions", columns: ["recording_id"])
            try db.create(indexOn: "actions", columns: ["ax_identifier"])
        }

        m.registerMigration("v2_ax_extended_fields") { db in
            // Richer identity captured at click time. All nullable — rows
            // created under v1 simply have these columns set to NULL.
            try db.alter(table: "actions") { t in
                t.add(column: "ax_help", .text)
                t.add(column: "ax_dom_identifier", .text)
                t.add(column: "ax_dom_class_list", .text) // JSON array
            }
            try db.create(indexOn: "actions", columns: ["ax_dom_identifier"])
        }

        m.registerMigration("v3_meta_kv") { db in
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }

        m.registerMigration("v4_fts5_deny_list") { db in
            // Full-text search over the fields that downstream agents
            // are most likely to query in natural language.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS actions_fts USING fts5(
                    ax_title, ax_value, ocr_text, window_title,
                    content='actions', content_rowid='id'
                )
                """)

            // Keep FTS index in sync via triggers. Cascading deletes
            // from recordings already go through DELETE on actions, so
            // the delete trigger covers those too.
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS actions_ai AFTER INSERT ON actions BEGIN
                    INSERT INTO actions_fts(rowid, ax_title, ax_value, ocr_text, window_title)
                    VALUES (new.id, new.ax_title, new.ax_value, new.ocr_text, new.window_title);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS actions_ad AFTER DELETE ON actions BEGIN
                    INSERT INTO actions_fts(actions_fts, rowid, ax_title, ax_value, ocr_text, window_title)
                    VALUES ('delete', old.id, old.ax_title, old.ax_value, old.ocr_text, old.window_title);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS actions_au AFTER UPDATE ON actions BEGIN
                    INSERT INTO actions_fts(actions_fts, rowid, ax_title, ax_value, ocr_text, window_title)
                    VALUES ('delete', old.id, old.ax_title, old.ax_value, old.ocr_text, old.window_title);
                    INSERT INTO actions_fts(rowid, ax_title, ax_value, ocr_text, window_title)
                    VALUES (new.id, new.ax_title, new.ax_value, new.ocr_text, new.window_title);
                END
                """)

            // Seed the deny list with common sensitive apps.
            try db.execute(sql: """
                INSERT OR IGNORE INTO meta (key, value) VALUES (
                    'deny_list_bundle_ids',
                    '["com.1password.1password","com.apple.keychainaccess","com.apple.Safari.PrivateBrowsing"]'
                )
                """)

            // Retention defaults (in days).
            try db.execute(sql: """
                INSERT OR IGNORE INTO meta (key, value) VALUES ('retention_screenshots_days', '30')
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO meta (key, value) VALUES ('retention_actions_days', '90')
                """)
        }

        return m
    }

    // MARK: - Session lifecycle

    @discardableResult
    func startSession() throws -> String {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO sessions (id, started_at) VALUES (?, ?)",
                arguments: [id, now]
            )
        }
        return id
    }

    func endSession(_ id: String) throws {
        let now = Date().timeIntervalSince1970
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET ended_at = ? WHERE id = ?",
                arguments: [now, id]
            )
        }
    }

    // MARK: - Recording lifecycle

    func insertRecording(id: String,
                         sessionID: String?,
                         name: String,
                         createdAt: Date,
                         duration: TimeInterval,
                         jsonPath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO recordings
                    (id, session_id, name, created_at, duration, json_path)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id, sessionID, name,
                    createdAt.timeIntervalSince1970,
                    duration, jsonPath
                ])
        }
    }

    func deleteRecording(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM recordings WHERE id = ?", arguments: [id])
        }
    }

    func deleteAllRecordings() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM recordings")
            try db.execute(sql: "DELETE FROM actions")
        }
    }

    // MARK: - Action inserts

    // MARK: - Meta key-value

    func getMeta(_ key: String) -> String? {
        try? dbQueue.read { db in
            try String.fetchOne(db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [key])
        }
    }

    func setMeta(_ key: String, _ value: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        }
    }

    // MARK: - Deny list

    /// Returns the set of bundle IDs that should never be captured.
    func denyListBundleIDs() -> Set<String> {
        guard let raw = getMeta("deny_list_bundle_ids"),
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return Set(arr)
    }

    // MARK: - Free-text search

    /// FTS5 search across `ax_title`, `ax_value`, `ocr_text` and
    /// `window_title`. Returns matching action IDs ordered by relevance.
    func searchActions(query: String, limit: Int = 50) throws -> [Int64] {
        try dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT rowid FROM actions_fts
                 WHERE actions_fts MATCH ?
                 ORDER BY rank
                 LIMIT ?
                """, arguments: [query, limit])
        }
    }

    // MARK: - Action queries

    /// Fetches all action rows with `id > afterID`, newest ones last.
    /// Used by the JSONL exporter to stream only the delta since its
    /// last high-water mark.
    func actionsAfter(id afterID: Int64, limit: Int = 10_000) throws -> [ActionExportRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, recording_id, session_id, ts, kind, x, y,
                       app_bundle_id, app_name, window_title,
                       ax_role, ax_subrole, ax_identifier, ax_title, ax_value,
                       ax_help, ax_dom_identifier, ax_dom_class_list,
                       ax_frame_json, url, source, screenshot_hash, ocr_text
                  FROM actions
                 WHERE id > ?
                 ORDER BY id ASC
                 LIMIT ?
                """, arguments: [afterID, limit])
            return rows.map { row in
                ActionExportRow(
                    id: row["id"],
                    recordingID: row["recording_id"],
                    sessionID: row["session_id"],
                    ts: row["ts"],
                    kind: row["kind"],
                    x: row["x"], y: row["y"],
                    appBundleID: row["app_bundle_id"],
                    appName: row["app_name"],
                    windowTitle: row["window_title"],
                    axRole: row["ax_role"],
                    axSubrole: row["ax_subrole"],
                    axIdentifier: row["ax_identifier"],
                    axTitle: row["ax_title"],
                    axValue: row["ax_value"],
                    axHelp: row["ax_help"],
                    axDomIdentifier: row["ax_dom_identifier"],
                    axDomClassList: row["ax_dom_class_list"],
                    axFrameJSON: row["ax_frame_json"],
                    url: row["url"],
                    source: row["source"],
                    screenshotHash: row["screenshot_hash"],
                    ocrText: row["ocr_text"]
                )
            }
        }
    }

    func insertAction(_ action: ActionRow) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO actions (
                    recording_id, session_id, ts, kind, x, y,
                    app_bundle_id, app_name, window_title,
                    ax_role, ax_subrole, ax_identifier, ax_title, ax_value,
                    ax_help, ax_dom_identifier, ax_dom_class_list,
                    ax_frame_json, url, source, screenshot_hash, ocr_text
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    action.recordingID, action.sessionID, action.ts, action.kind,
                    action.x, action.y,
                    action.appBundleID, action.appName, action.windowTitle,
                    action.axRole, action.axSubrole, action.axIdentifier,
                    action.axTitle, action.axValue,
                    action.axHelp, action.axDomIdentifier, action.axDomClassList,
                    action.axFrameJSON, action.url,
                    action.source, action.screenshotHash, action.ocrText
                ])
        }
    }
}

/// Flat row for inserting into `actions`. Mirrors the schema one-to-one so
/// the enricher can produce one of these and hand it to `Database`.
/// Flat row used by the JSONL exporter — same shape as `ActionRow` but
/// carries the auto-incremented primary key so the exporter can track
/// its high-water mark.
struct ActionExportRow {
    var id: Int64
    var recordingID: String?
    var sessionID: String?
    var ts: TimeInterval
    var kind: String
    var x: Double?
    var y: Double?
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    var axRole: String?
    var axSubrole: String?
    var axIdentifier: String?
    var axTitle: String?
    var axValue: String?
    var axHelp: String?
    var axDomIdentifier: String?
    var axDomClassList: String?
    var axFrameJSON: String?
    var url: String?
    var source: String
    var screenshotHash: String?
    var ocrText: String?
}

struct ActionRow {
    var recordingID: String?
    var sessionID: String?
    var ts: TimeInterval
    var kind: String
    var x: Double?
    var y: Double?
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    var axRole: String?
    var axSubrole: String?
    var axIdentifier: String?
    var axTitle: String?
    var axValue: String?
    var axHelp: String?
    var axDomIdentifier: String?
    var axDomClassList: String?   // JSON array of strings
    var axFrameJSON: String?
    var url: String?
    var source: String            // "ax" | "ocr" | "hybrid" | "none"
    var screenshotHash: String?
    var ocrText: String?
}
