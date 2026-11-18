import Darwin
import Foundation

/// What macOS says about one file in iCloud Drive.
public struct CloudItemState: Sendable, Equatable {
    /// Managed by iCloud at all (false for a plain local file).
    public var isUbiquitous: Bool
    /// Its current content is in iCloud. Only then may the local copy go.
    public var isUploaded: Bool
    /// The content is on this Mac right now (false once evicted: the file is a placeholder that downloads on read).
    public var isLocal: Bool
    /// Bytes it occupies on this Mac's disk (0 once evicted).
    public var allocatedBytes: Int64

    public init(isUbiquitous: Bool, isUploaded: Bool, isLocal: Bool, allocatedBytes: Int64) {
        self.isUbiquitous = isUbiquitous
        self.isUploaded = isUploaded
        self.isLocal = isLocal
        self.allocatedBytes = allocatedBytes
    }
}

/// Upload state and eviction of files in iCloud Drive. Injectable so tests never touch the real iCloud.
public protocol CloudStorage: Sendable {
    /// Nil when the file doesn't exist.
    func state(of url: URL) -> CloudItemState?
    /// Removes the local copy of a file that is in iCloud. The file stays listed and downloads again when read.
    func evict(_ url: URL) throws
}

/// The real thing: URL resource values and `FileManager.evictUbiquitousItem`, which itself refuses a file that
/// isn't uploaded yet.
public struct LiveCloudStorage: CloudStorage {
    public init() {}

    public func state(of url: URL) -> CloudItemState? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                                         .ubiquitousItemDownloadingStatusKey])
        let ubiquitous = values?.isUbiquitousItem ?? false
        let status = values?.ubiquitousItemDownloadingStatus
        return CloudItemState(isUbiquitous: ubiquitous,
                              isUploaded: ubiquitous && (values?.ubiquitousItemIsUploaded ?? false),
                              isLocal: !ubiquitous || status != .notDownloaded,
                              allocatedBytes: Int64(st.st_blocks) * 512)
    }

    public func evict(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}

/// A fake iCloud for fixture mode and tests: files are plain local files; "uploaded" is whatever the test says, and
/// evicting only records the path (the file's content stays, so a later restore can still read it).
public final class FakeCloudStorage: CloudStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var _uploadedAll: Bool
    private var _uploaded = Set<String>()
    private var _evicted = Set<String>()
    private var _evictError: String?

    public init(uploaded: Bool = false) { _uploadedAll = uploaded }

    /// Every file counts as uploaded.
    public var uploaded: Bool {
        get { lock.withLock { _uploadedAll } }
        set { lock.withLock { _uploadedAll = newValue } }
    }

    public func markUploaded(_ url: URL) { lock.withLock { _ = _uploaded.insert(Self.key(url)) } }

    /// Makes `evict` fail with this message.
    public var evictError: String? {
        get { lock.withLock { _evictError } }
        set { lock.withLock { _evictError = newValue } }
    }

    public var evicted: [String] { lock.withLock { _evicted.sorted() } }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path(percentEncoded: false) }

    public func state(of url: URL) -> CloudItemState? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        let key = Self.key(url)
        return lock.withLock {
            let gone = _evicted.contains(key)
            return CloudItemState(isUbiquitous: true, isUploaded: _uploadedAll || _uploaded.contains(key), isLocal: !gone,
                                  allocatedBytes: gone ? 0 : Int64(st.st_blocks) * 512)
        }
    }

    public func evict(_ url: URL) throws {
        let key = Self.key(url)
        try lock.withLock {
            if let _evictError { throw OffloadError.io(_evictError) }
            guard _uploadedAll || _uploaded.contains(key) else { throw OffloadError.refused("not uploaded yet") }
            _evicted.insert(key)
        }
    }
}

public struct EvictionResult: Sendable, Identifiable {
    public enum Status: Sendable, Equatable {
        /// Dry run: uploaded and still taking space here.
        case wouldEvict
        /// The local copy was removed; the archive is in iCloud only.
        case evicted
        /// Nothing to do: the local copy is already gone.
        case alreadyEvicted
        /// macOS hasn't finished uploading it; the local copy is the only complete one, so it stays.
        case notUploaded
        /// The archive isn't in iCloud Drive (e.g. it's on a NAS).
        case notInICloud
        /// The archive isn't where the record says.
        case missing
        case failed(String)
    }

    public var id: UUID { record.id }
    public var record: OffloadRecord
    public var status: Status
    /// Bytes the local copy takes (what evicting frees, or freed).
    public var localBytes: Int64
}

public struct EvictionReport: Sendable {
    public var dryRun: Bool
    public var results: [EvictionResult]
    /// Measured change in free space (0 in a dry run). macOS can take a moment to give the space back.
    public var reclaimedBytes: Int64

    public var evictedCount: Int { results.filter { $0.status == .evicted }.count }
    public var evictableBytes: Int64 {
        results.filter { $0.status == .wouldEvict || $0.status == .evicted }.reduce(0) { $0 + $1.localBytes }
    }
    public var waitingForUpload: Int { results.filter { $0.status == .notUploaded }.count }
}

extension OffloadEngine {
    /// Frees the space offloaded archives still take on this Mac when the destination is iCloud Drive.
    ///
    /// An offload to iCloud Drive first lands on this Mac's own disk; macOS then uploads it. Only once macOS reports
    /// the payload as uploaded is its local copy evicted — the file stays in iCloud Drive (and in Finder) and is
    /// downloaded again when it is restored. `manifest.json` is never evicted, so the Offloaded list keeps working
    /// offline. Nothing is deleted, here or in iCloud. Dry run unless `execute`.
    public func evictLocalCopies(_ records: [OffloadRecord]? = nil, execute: Bool = false) -> EvictionReport {
        let before = VolumeInfo.availableBytes(at: context.home) ?? 0
        var results: [EvictionResult] = []
        for record in records ?? store.records() {
            let payload = URL(filePath: record.manifest.payloadPath)
            var result = EvictionResult(record: record, status: .missing, localBytes: 0)
            defer { results.append(result) }
            let archiveDir = URL(filePath: record.manifest.archivePath, directoryHint: .isDirectory)
            guard let volume = probe.status(of: archiveDir) else { continue }
            guard volume.isICloud else {
                result.status = .notInICloud
                continue
            }
            guard let state = cloud.state(of: payload) else { continue }
            result.localBytes = state.allocatedBytes
            guard state.isLocal, state.allocatedBytes > 0 else {
                result.status = .alreadyEvicted
                continue
            }
            guard state.isUploaded else {
                result.status = .notUploaded
                continue
            }
            guard execute else {
                result.status = .wouldEvict
                continue
            }
            do {
                try cloud.evict(payload)
                result.status = .evicted
            } catch {
                result.status = .failed((error as? OffloadError)?.description ?? error.localizedDescription)
            }
        }
        guard execute else { return EvictionReport(dryRun: true, results: results, reclaimedBytes: 0) }
        // Eviction is asynchronous: give macOS a moment before measuring.
        let evicted = results.filter { $0.status == .evicted }
        if !evicted.isEmpty {
            for _ in 0..<30 {
                let pending = evicted.contains {
                    (cloud.state(of: URL(filePath: $0.record.manifest.payloadPath))?.allocatedBytes ?? 0) > 0
                }
                if !pending { break }
                usleep(100_000)
            }
        }
        let reclaimed = (VolumeInfo.availableBytes(at: context.home) ?? 0) - before
        appendEvictionHistory(results, reclaimed: reclaimed)
        return EvictionReport(dryRun: false, results: results, reclaimedBytes: reclaimed)
    }

    private func appendEvictionHistory(_ results: [EvictionResult], reclaimed: Int64) {
        let attempted = results.filter { r in
            if r.status == .evicted { return true }
            if case .failed = r.status { return true }
            return false
        }
        guard !attempted.isEmpty else { return }
        let items = attempted.map { r -> HistoryEntry.ItemRecord in
            var error: String?
            if case .failed(let e) = r.status { error = e }
            return HistoryEntry.ItemRecord(ruleID: "offload:evict", itemID: r.record.id.uuidString,
                                           displayName: r.record.manifest.displayName, path: r.record.manifest.payloadPath,
                                           method: "free the local copy (kept in iCloud Drive)", estimatedBytes: r.localBytes,
                                           succeeded: r.status == .evicted, error: error)
        }
        let estimate = attempted.filter { $0.status == .evicted }.reduce(Int64(0)) { $0 + $1.localBytes }
        try? history.append(HistoryEntry(id: UUID(), date: Date(), ruleIDs: ["offload:evict"], items: items,
                                         estimatedBytes: estimate, reclaimedBytes: reclaimed))
    }
}
