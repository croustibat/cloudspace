import Foundation

public enum OffloadError: Error, Sendable, Equatable, CustomStringConvertible {
    case notMounted(String)
    case notNetworkVolume(String)
    case destinationUnavailable(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case shareChanged(String)
    case io(String)
    case verification(String)
    case sourceChanged(String)
    case refused(String)
    case alreadyExists(String)
    case manifest(String)
    case cancelled

    public var description: String {
        switch self {
        case .notMounted(let s): "the NAS share isn't mounted: \(s)"
        case .notNetworkVolume(let s): "not a mounted network share: \(s)"
        case .destinationUnavailable(let s): "destination unavailable: \(s)"
        case .insufficientSpace(let needed, let available):
            "not enough space: needs \(ByteFormat.string(needed)), \(ByteFormat.string(available)) free"
        case .shareChanged(let s): "the NAS share went away during the copy: \(s)"
        case .io(let s): s
        case .verification(let s): "verification failed: \(s)"
        case .sourceChanged(let s): "the original changed while it was being copied (\(s)); it was left in place"
        case .refused(let s): "refused: \(s)"
        case .alreadyExists(let s): "something already exists at \(s); nothing was overwritten"
        case .manifest(let s): "manifest problem: \(s)"
        case .cancelled: "cancelled"
        }
    }
}

/// One file, folder or link inside an offloaded item.
public struct OffloadEntry: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case file, directory, symlink }

    /// Relative to the item; "" is the item itself.
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var mode: UInt16
    public var modified: Date
    /// SHA-256 of the whole file, computed from the original while it was copied.
    public var sha256: String?
    /// For files over the checksum cap: SHA-256 of the first and last 4 MiB (what the NAS read-back compares).
    public var sampleSHA256: String?
    public var linkTarget: String?
    public var xattrCount: Int?
    public var xattrDigest: String?
}

public enum OffloadKind: String, Codable, Sendable, CaseIterable {
    case project, xcodeArchive, file

    /// Top-level folder on the share.
    public var folder: String {
        switch self {
        case .project: "projects"
        case .xcodeArchive: "xcode-archives"
        case .file: "files"
        }
    }

    public var title: String {
        switch self {
        case .project: "Stale projects"
        case .xcodeArchive: "Xcode Archives"
        case .file: "Large cold files"
        }
    }
}

public enum OffloadFormat: String, Codable, Sendable {
    /// A folder (or a file with large extended attributes) packed into one pax tar.
    case tar
    /// A single regular file copied as-is (browsable on the NAS); its extended attributes live in the manifest.
    case file
}

/// Written next to the payload on the NAS and kept locally: everything needed to verify and restore.
public struct OffloadManifest: Codable, Sendable, Identifiable {
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var kind: OffloadKind
    public var displayName: String
    /// Where the original lived.
    public var sourcePath: String
    public var sourceHost: String
    public var createdAt: Date
    public var format: OffloadFormat
    /// File name of the payload inside `archivePath`.
    public var payloadName: String
    public var payloadBytes: Int64
    public var payloadSHA256: String
    /// The archive folder on the NAS (`<share>/<kind>/<name>/<timestamp>`).
    public var archivePath: String
    /// Sum of file sizes (what a restore writes).
    public var contentBytes: Int64
    public var fileCount: Int
    public var directoryCount: Int
    public var symlinkCount: Int
    /// Checksum cap in force: files up to this size were re-read from the NAS and fully compared.
    public var checksumCapBytes: Int64
    /// Things that couldn't be archived (sockets, FIFOs, other volumes mounted inside).
    public var skipped: [String]
    /// Extended attributes of a `.file` payload (a tar carries its own).
    public var fileXattrs: [String: Data]?
    /// How to get it back without CloudSpace.
    public var restoreCommand: String
    /// E.g. a hibernated project's reinstall commands.
    public var notes: [String]
    /// Empty in the local summary copy (`OffloadRecord`); complete in the manifest files.
    public var entries: [OffloadEntry]

    public var payloadPath: String { archivePath + "/" + payloadName }
    public var manifestPath: String { archivePath + "/manifest.json" }
}

/// Local state of one offload: the manifest summary plus what happened to the original and later restores.
public struct OffloadRecord: Codable, Sendable, Identifiable, Hashable {
    public struct Restore: Codable, Sendable, Hashable {
        public var date: Date
        public var path: String
    }

    public enum OriginalState: Codable, Sendable, Hashable {
        /// Moved to the Trash after verification.
        case trashed(Date)
        /// Copy verified, but the original was left where it was (why).
        case kept(String)
    }

    public var manifest: OffloadManifest
    public var original: OriginalState
    public var restores: [Restore]
    /// True when this record was found on the NAS rather than created on this Mac.
    public var importedFromShare: Bool

    public var id: UUID { manifest.id }

    public static func == (a: OffloadRecord, b: OffloadRecord) -> Bool {
        a.id == b.id && a.original == b.original && a.restores == b.restores
    }

    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Something that could go to the NAS.
public struct OffloadCandidate: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path.path }
    public var kind: OffloadKind
    public var path: URL
    public var displayName: String
    /// Allocated size on disk (what offloading frees once the Trash is emptied).
    public var size: Int64?
    public var lastUsed: Date?
    public var note: String?
    /// Rule that produced it (archives and files); re-resolved before anything is touched.
    public var ruleID: String?
    /// Projects: dependency/build folders that would be copied too unless the project is hibernated first.
    public var strippableBytes: Int64
    public var strippableDirs: [String]
    /// Projects: git warnings (informational: the whole repository goes into the archive).
    public var warnings: [String]
    /// Projects: how dependencies come back after a restore.
    public var restoreCommands: [String]

    public init(kind: OffloadKind, path: URL, displayName: String, size: Int64? = nil, lastUsed: Date? = nil,
                note: String? = nil, ruleID: String? = nil, strippableBytes: Int64 = 0, strippableDirs: [String] = [],
                warnings: [String] = [], restoreCommands: [String] = []) {
        self.kind = kind
        self.path = path.standardizedFileURL
        self.displayName = displayName
        self.size = size
        self.lastUsed = lastUsed
        self.note = note
        self.ruleID = ruleID
        self.strippableBytes = strippableBytes
        self.strippableDirs = strippableDirs
        self.warnings = warnings
        self.restoreCommands = restoreCommands
    }

    public var shouldHibernateFirst: Bool { kind == .project && strippableBytes > 0 }
}

/// Local copies of manifests and offload state (`~/Library/Application Support/MajorTom/offloads/`).
public final class OffloadStore: Sendable {
    public let directory: URL

    public init(directory: URL = AppSupport.directory().appending(path: "offloads", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func recordURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }
    func manifestURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).manifest.json") }

    public func save(_ record: OffloadRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var r = record
        r.manifest.entries = []
        try Self.encoder.encode(r).write(to: recordURL(record.id), options: .atomic)
    }

    public func saveManifest(_ manifest: OffloadManifest) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(manifest).write(to: manifestURL(manifest.id), options: .atomic)
    }

    /// Newest first.
    public func records() -> [OffloadRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".manifest.json") }
            .compactMap { try? Self.decoder.decode(OffloadRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public func record(id: UUID) -> OffloadRecord? {
        try? Self.decoder.decode(OffloadRecord.self, from: Data(contentsOf: recordURL(id)))
    }

    public func manifest(id: UUID) -> OffloadManifest? {
        try? Self.decoder.decode(OffloadManifest.self, from: Data(contentsOf: manifestURL(id)))
    }
}
