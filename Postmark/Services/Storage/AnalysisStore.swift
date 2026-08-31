import Foundation
import SQLite3

/// SQLite-backed store for per-message triage outcomes and the cooldown
/// ledger. Message-ID is the primary key; `processed_at` drives both the 24h
/// cooldown window and retention pruning, so thousands of processed messages
/// cost a few MB at most. Replaces the ad-hoc `cooldown.json`.
@MainActor
final class AnalysisStore {
    static let shared = AnalysisStore()

    /// `Self.sqliteTransient` isn't exported to Swift; it's the destructor sentinel
    /// telling SQLite to copy bound text before the caller's buffers disappear.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// How long a processed message suppresses re-processing.
    let cooldownTTL: TimeInterval = 24 * 60 * 60
    /// Retention for analysis rows (beyond cooldown, for audit / the digest).
    let retentionDays: Int = 14

    private var db: OpaquePointer?

    private let dbURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("analysis.sqlite")
    }()

    private let legacyCooldownURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postmark", isDirectory: true)
        return dir.appendingPathComponent("cooldown.json")
    }()

    private init() {
        open()
        createSchema()
        prune()
        importLegacyCooldownIfPresent()
    }

    // MARK: - Queries

    /// True when the message was already processed within the cooldown window.
    func isOnCooldown(messageID: String) -> Bool {
        guard let db else { return false }
        let cutoff = Date().timeIntervalSince1970 - cooldownTTL
        let sql = "SELECT 1 FROM processed_message WHERE message_id = ?1 AND processed_at > ?2"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (messageID as NSString).utf8String, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 2, cutoff)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Record a successful triage outcome (upserts by message ID and ticks the
    /// cooldown). Only called after classification succeeds.
    func recordProcessed(
        messageID: String,
        subject: String,
        sender: String,
        category: String,
        forwarded: [String],
        errors: [String],
        tookAction: Bool
    ) {
        recordProcessed(
            messageID: messageID,
            subject: subject,
            sender: sender,
            category: category,
            forwarded: forwarded,
            errors: errors,
            tookAction: tookAction,
            processedAt: Date().timeIntervalSince1970
        )
    }

    private func recordProcessed(
        messageID: String,
        subject: String,
        sender: String,
        category: String,
        forwarded: [String],
        errors: [String],
        tookAction: Bool,
        processedAt: TimeInterval
    ) {
        guard let db else { return }
        let sql = """
        INSERT OR REPLACE INTO processed_message
            (message_id, subject, sender, category, forwarded, errors, took_action, processed_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (messageID as NSString).utf8String, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, (subject as NSString).utf8String, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, (sender as NSString).utf8String, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 4, (category as NSString).utf8String, -1, Self.sqliteTransient)
        let fwd = encodeList(forwarded)
        let err = encodeList(errors)
        sqlite3_bind_text(stmt, 5, (fwd as NSString).utf8String, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 6, (err as NSString).utf8String, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 7, tookAction ? 1 : 0)
        sqlite3_bind_double(stmt, 8, processedAt)
        sqlite3_step(stmt)
        prune()
    }

    /// Empty the whole store (dev menu: "Clear Cooldown & Analysis").
    func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM processed_message", nil, nil, nil)
    }

    func prune() {
        guard let db else { return }
        let cutoff = Date().timeIntervalSince1970 - TimeInterval(retentionDays * 24 * 60 * 60)
        let sql = "DELETE FROM processed_message WHERE processed_at < ?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }

    // MARK: - Setup / migration

    private func open() {
        var handle: OpaquePointer?
        guard let path = (dbURL.path as NSString).utf8String else { return }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else { return }
        db = handle
    }

    private func createSchema() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS processed_message (
            message_id  TEXT PRIMARY KEY,
            subject     TEXT NOT NULL DEFAULT '',
            sender      TEXT NOT NULL DEFAULT '',
            category    TEXT NOT NULL DEFAULT '',
            forwarded   TEXT NOT NULL DEFAULT '[]',
            errors      TEXT NOT NULL DEFAULT '[]',
            took_action INTEGER NOT NULL DEFAULT 0,
            processed_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_processed_at ON processed_message(processed_at);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// One-time carry-over of the old JSON cooldown ledger into SQLite.
    private func importLegacyCooldownIfPresent() {
        guard let data = try? Data(contentsOf: legacyCooldownURL),
              let legacy = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return }
        for (messageID, date) in legacy {
            recordProcessed(
                messageID: messageID,
                subject: "",
                sender: "",
                category: "migrated",
                forwarded: [],
                errors: [],
                tookAction: false,
                processedAt: date.timeIntervalSince1970
            )
        }
        try? FileManager.default.removeItem(at: legacyCooldownURL)
    }

    private func encodeList(_ items: [String]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}