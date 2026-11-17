import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable {
    public struct ItemRecord: Codable, Sendable {
        public var ruleID: String
        public var itemID: String
        public var displayName: String
        public var path: String?
        public var method: String
        public var estimatedBytes: Int64?
        public var succeeded: Bool
        /// User-facing reason (with what to do) when it failed or was only partly removed.
        public var error: String?
        /// True when part of it was removed and part left behind (`succeeded` is false then).
        public var partial: Bool? = nil
        /// What was left behind and why (deletes only; capped).
        public var leftBehind: [LeftBehind]? = nil
        /// The raw error(s) behind `error`, e.g. "rmdir: Directory not empty (errno 66)".
        public var underlyingError: String? = nil
    }

    public var id: UUID
    public var date: Date
    public var ruleIDs: [String]
    public var items: [ItemRecord]
    /// Sum of scan estimates for the items that succeeded.
    public var estimatedBytes: Int64
    /// Measured change in volume free space (what was actually reclaimed).
    public var reclaimedBytes: Int64
}

/// Append-only JSON-lines log of real cleans.
public final class HistoryLog: Sendable {
    public let url: URL

    public init(url: URL = AppSupport.directory().appending(path: "history.jsonl")) {
        self.url = url
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public func append(_ entry: HistoryEntry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// All entries, oldest first. Malformed lines are skipped.
    public func entries() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? dec.decode(HistoryEntry.self, from: Data($0)) }
    }
}
