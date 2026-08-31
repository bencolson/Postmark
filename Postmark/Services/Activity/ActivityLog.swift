import Foundation

/// Append-only activity journal backing the Activity window. Each entry is
/// mirrored to a JSONL file in Application Support (rotated at ~10k lines) and
/// kept in a bounded in-memory ring for the window. Privacy: callers must never
/// log email bodies, payloads, provider keys, or the raw Silo inbound address.
@MainActor
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    enum Kind: String, Codable {
        case app
        case poll
        case classify
        case action
        case silo
        case error
    }

    enum Level: String, Codable, Comparable {
        case debug
        case info
        case warn
        case error

        private static func order(_ level: Level) -> Int {
            switch level {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { order(lhs) < order(rhs) }
    }

    struct Entry: Identifiable, Codable {
        var id = UUID()
        var timestamp: Date
        var kind: Kind
        var level: Level
        var message: String
        var messageID: String?
    }

    @Published private(set) var entries: [Entry] = []

    let fileURL: URL
    private let ringCap = 2000
    private let maxLines = 10_000
    private var linesAppended: Int

    private let logQueue = DispatchQueue(label: "digital.colson.postmark.activity", qos: .utility)

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("activity.log")
        linesAppended = Self.countLines(at: fileURL)
        loadTail()
    }

    // MARK: - Record

    func record(_ message: String, kind: Kind, level: Level = .info, messageID: String? = nil) {
        let entry = Entry(
            timestamp: Date(),
            kind: kind,
            level: level,
            message: message,
            messageID: messageID
        )
        entries.append(entry)
        if entries.count > ringCap {
            entries.removeFirst(entries.count - ringCap)
        }

        let line = Self.encode(entry)
        let logURL = fileURL
        logQueue.async {
            Self.append(line, to: logURL)
        }

        linesAppended += 1
        if linesAppended > maxLines {
            linesAppended = 0
            let rotatedURL = URL(fileURLWithPath: fileURL.path + ".1")
            logQueue.async {
                Self.rotate(from: logURL, to: rotatedURL)
            }
        }
    }

    /// Drop the in-memory ring only — the log file is left untouched.
    func clear() {
        entries.removeAll()
    }

    // MARK: - File helpers

    private nonisolated static func encode(_ entry: Entry) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              let text = String(data: data, encoding: .utf8)
        else {
            return #"{"timestamp":"1970-01-01T00:00:00Z","kind":"error","level":"error","message":"encode failure"}"#
        }
        return text
    }

    private nonisolated static func append(_ line: String, to url: URL) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    private nonisolated static func rotate(from url: URL, to rotatedURL: URL) {
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }

    private nonisolated static func countLines(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        var count = 0
        for byte in data where byte == 0x0A { count += 1 }
        return count
    }

    private func loadTail() {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [Entry] = []
        for line in raw.split(separator: "\n").suffix(ringCap) {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data)
            else { continue }
            loaded.append(entry)
        }
        entries = loaded
    }
}