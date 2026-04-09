import Foundation
import CryptoKit

/// Content-addressed PNG storage. Screenshots are saved under a
/// SHA-256-based sharded directory tree so identical frames deduplicate
/// and "delete all" is just `rm -rf blobs/`.
///
/// Layout:
///
///     ~/Library/Application Support/Bitscope/blobs/<aa>/<bb>/<full-hash>.png
///
final class BlobStore {
    let root: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        root = base.appendingPathComponent("Bitscope/blobs", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Stores PNG data and returns the hex SHA-256 hash (used as the
    /// `screenshot_hash` column value). Returns nil on write failure.
    @discardableResult
    func store(png data: Data) -> String? {
        let hash = SHA256.hash(data: data)
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        let prefix1 = String(hex.prefix(2))
        let prefix2 = String(hex.dropFirst(2).prefix(2))
        let dir = root
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
        let file = dir.appendingPathComponent("\(hex).png")

        // Skip if already stored (content-addressed → idempotent).
        if FileManager.default.fileExists(atPath: file.path) { return hex }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return hex
        } catch {
            NSLog("BlobStore: failed to write \(hex).png: \(error)")
            return nil
        }
    }

    /// Returns the on-disk URL for a hash, or nil if it doesn't exist.
    func url(for hash: String) -> URL? {
        let prefix1 = String(hash.prefix(2))
        let prefix2 = String(hash.dropFirst(2).prefix(2))
        let file = root
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
            .appendingPathComponent("\(hash).png")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Wipes the entire blob tree.
    func deleteAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
