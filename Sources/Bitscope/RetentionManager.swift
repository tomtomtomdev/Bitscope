import Foundation

/// Enforces data retention policies on launch. Runs once per app
/// session (called from `AppModel.init`). Controllable via the `meta`
/// table keys:
///
///  - `retention_screenshots_days` — blobs older than this are deleted
///    and `screenshot_hash` is set to NULL. Default 30.
///  - `retention_actions_days` — action rows older than this are deleted
///    entirely. Default 90.
///
/// The design is "delete the heaviest stuff first": images go before
/// text, and the text index (FTS5) is kept in sync via triggers.
final class RetentionManager {
    private let database: Database
    private let blobStore: BlobStore

    init(database: Database, blobStore: BlobStore) {
        self.database = database
        self.blobStore = blobStore
    }

    func enforce() {
        let screenshotDays = Int(database.getMeta("retention_screenshots_days") ?? "") ?? 30
        let actionDays = Int(database.getMeta("retention_actions_days") ?? "") ?? 90

        let now = Date().timeIntervalSince1970

        // Phase 1: Expire screenshot blobs older than the retention window.
        let screenshotCutoff = now - Double(screenshotDays) * 86_400
        expireScreenshots(before: screenshotCutoff)

        // Phase 2: Delete action rows (and their FTS shadows) older than
        // the action retention window.
        let actionCutoff = now - Double(actionDays) * 86_400
        expireActions(before: actionCutoff)
    }

    private func expireScreenshots(before cutoff: TimeInterval) {
        do {
            // Collect hashes that are about to lose their rows.
            let hashes: [String] = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT screenshot_hash
                      FROM actions
                     WHERE ts < ? AND screenshot_hash IS NOT NULL
                    """, arguments: [cutoff])
            }

            // NULL-ify the column so the row survives (text is still useful).
            try database.dbQueue.write { db in
                try db.execute(sql: """
                    UPDATE actions SET screenshot_hash = NULL
                     WHERE ts < ? AND screenshot_hash IS NOT NULL
                    """, arguments: [cutoff])
            }

            // Delete blobs that are no longer referenced by any row.
            for hash in hashes {
                let stillReferenced: Bool = try database.dbQueue.read { db in
                    let count = try Int.fetchOne(db, sql: """
                        SELECT count(*) FROM actions
                         WHERE screenshot_hash = ?
                        """, arguments: [hash]) ?? 0
                    return count > 0
                }
                if !stillReferenced, let url = blobStore.url(for: hash) {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            if !hashes.isEmpty {
                NSLog("RetentionManager: expired \(hashes.count) screenshot blob(s)")
            }
        } catch {
            NSLog("RetentionManager: screenshot expiry error: \(error)")
        }
    }

    private func expireActions(before cutoff: TimeInterval) {
        do {
            let deleted = try database.dbQueue.write { db -> Int in
                try db.execute(sql: "DELETE FROM actions WHERE ts < ?", arguments: [cutoff])
                return db.changesCount
            }
            if deleted > 0 {
                NSLog("RetentionManager: deleted \(deleted) expired action(s)")
            }
        } catch {
            NSLog("RetentionManager: action expiry error: \(error)")
        }
    }
}
