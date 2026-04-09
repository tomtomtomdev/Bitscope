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

    func insertAction(_ action: ActionRow) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO actions (
                    recording_id, session_id, ts, kind, x, y,
                    app_bundle_id, app_name, window_title,
                    ax_role, ax_subrole, ax_identifier, ax_title, ax_value,
                    ax_frame_json, url, source, screenshot_hash, ocr_text
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    action.recordingID, action.sessionID, action.ts, action.kind,
                    action.x, action.y,
                    action.appBundleID, action.appName, action.windowTitle,
                    action.axRole, action.axSubrole, action.axIdentifier,
                    action.axTitle, action.axValue, action.axFrameJSON, action.url,
                    action.source, action.screenshotHash, action.ocrText
                ])
        }
    }
}

/// Flat row for inserting into `actions`. Mirrors the schema one-to-one so
/// the enricher can produce one of these and hand it to `Database`.
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
    var axFrameJSON: String?
    var url: String?
    var source: String        // "ax" | "ocr" | "hybrid"
    var screenshotHash: String?
    var ocrText: String?
}
