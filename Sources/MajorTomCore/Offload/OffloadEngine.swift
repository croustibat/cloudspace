import CryptoKit
import Darwin
import Foundation

public struct OffloadProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case checking = "Checking"
        case copying = "Copying to the NAS"
        case verifying = "Verifying the copy on the NAS"
        case finishing = "Writing the manifest"
        case trashing = "Moving the original to the Trash"
        case restoring = "Copying back from the NAS"
        case checkingRestore = "Checking the restored copy"
    }

    public var itemIndex: Int
    public var itemCount: Int
    public var itemName: String
    public var phase: Phase
    /// Within the current phase.
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// 0…1 across the whole batch (copy and verify each count once).
    public var overallFraction: Double
    /// Copy / read speed of the current phase.
    public var bytesPerSecond: Double?
}

public struct OffloadItemResult: Sendable, Identifiable {
    public enum Status: Sendable, Equatable {
        /// Dry run: everything checks out.
        case wouldOffload
        /// Copied and verified; `trashed` says whether the original went to the Trash (see the record if not).
        case offloaded(trashed: Bool)
        /// Nothing was changed locally.
        case failed(String)
        /// Refused before anything was copied.
        case skipped(String)
        case cancelled
    }

    public var id: String { candidate.id }
    public var candidate: OffloadCandidate
    public var status: Status
    public var record: OffloadRecord?
    /// Payload size on the NAS (or the estimate in a dry run).
    public var payloadBytes: Int64
    public var copySeconds: Double
    /// What happened to an incomplete copy on the NAS after a failure.
    public var partialNote: String?
}

public struct OffloadReport: Sendable {
    public var dryRun: Bool
    public var destination: DestinationCheck
    public var results: [OffloadItemResult]
    public var duration: TimeInterval

    public var offloadedCount: Int { results.filter { if case .offloaded = $0.status { true } else { false } }.count }
    public var trashedBytes: Int64 {
        results.filter { $0.status == .offloaded(trashed: true) }.reduce(0) { $0 + ($1.candidate.size ?? 0) }
    }
}

public struct RestoreResult: Sendable {
    public var record: OffloadRecord
    /// Where it was restored to (or would have been).
    public var target: URL
    public var error: OffloadError?
    public var bytes: Int64
    public var seconds: Double
    /// Extended attributes macOS wouldn't let us set again (informational).
    public var xattrFailures: Int

    public var succeeded: Bool { error == nil }
}

/// NAS offload (M6): copy → verify → manifest (on the NAS and locally) → only then move the original to the Trash.
///
/// Safety:
/// - Nothing happens unless the destination is on a mounted network volume (`VolumeProbe`), checked before every item
///   and every 64 MB while copying; a plain local folder at the mount point is refused.
/// - Every candidate is re-resolved and its path re-validated (as the clean engine does) before copying and again
///   right before it is trashed. Projects must still be stale, archives/files must still be listed by their rule.
/// - The original is only ever moved to the Trash, never deleted, and only after every file has been verified on the
///   NAS and the original was re-walked and found unchanged. Any error or cancellation leaves it untouched and removes
///   the incomplete `.partial` copy on the NAS (or leaves it clearly marked if the share is gone).
/// - Nothing on the NAS is ever overwritten: each offload claims a new dated folder.
/// - Restore refuses to overwrite anything, verifies before moving the result into place, and never deletes the NAS copy.
/// - Dry run unless `execute: true`.
public struct OffloadEngine: Sendable {
    /// Test seams for failure injection.
    public struct Hooks: Sendable {
        /// Runs after the payload is written and synced, before it is verified (tests corrupt it here).
        public var afterPayloadWritten: (@Sendable (URL) -> Void)?
        /// Called with the bytes written so far; returning an error makes the write fail there.
        public var writeFault: (@Sendable (Int64) -> OffloadError?)?
        public init(afterPayloadWritten: (@Sendable (URL) -> Void)? = nil, writeFault: (@Sendable (Int64) -> OffloadError?)? = nil) {
            self.afterPayloadWritten = afterPayloadWritten
            self.writeFault = writeFault
        }
    }

    public static let archiveRuleIDs: Set<String> = ["xcode-archives", "fx-archives"]
    public static let fileRuleIDs: Set<String> = ["large-files", "old-files"]
    /// Large files count as cold when unused for this long (old files are cold by definition).
    public static let coldFileDays = 90
    public static let defaultChecksumCapMB = 1024

    /// The folder on the share; nil until the user chooses one (every offload then fails with `.notSet`).
    public var destination: URL?
    public var probe: any VolumeProbe
    /// Upload state and eviction of copies in iCloud Drive.
    public var cloud: any CloudStorage
    public var context: RuleContext
    public var rules: [Rule]
    public var git: any CommandRunner
    public var store: OffloadStore
    public var remover: any FileRemover
    public var history: HistoryLog
    public var checksumCapBytes: Int64
    public var hooks: Hooks
    /// Re-check the share every this many bytes.
    public var mountCheckInterval: Int64 = 64 * 1024 * 1024

    public init(destination: URL?, probe: any VolumeProbe = LiveVolumeProbe(), cloud: any CloudStorage = LiveCloudStorage(),
                context: RuleContext,
                rules: [Rule] = RuleCatalogue.all, git: any CommandRunner = ProcessRunner(), store: OffloadStore = OffloadStore(),
                remover: any FileRemover = SystemFileRemover(), history: HistoryLog = HistoryLog(),
                checksumCapBytes: Int64? = nil, hooks: Hooks = Hooks()) {
        self.destination = destination?.standardizedFileURL
        self.probe = probe
        self.cloud = cloud
        self.context = context
        self.rules = rules
        self.git = git
        self.store = store
        self.remover = remover
        self.history = history
        self.checksumCapBytes = checksumCapBytes
            ?? Int64(max(1, context.settings.offloadChecksumCapMB)) * 1_000_000
        self.hooks = hooks
    }

    public func checkDestination() -> DestinationCheck {
        guard let destination else { return .notSet }
        return DestinationCheck.check(destination, probe: probe)
    }

    /// The destination, for steps that run only after `checkDestination()` said it's ready.
    private func requireDestination() throws -> URL {
        guard let destination else { throw OffloadError.notNetworkVolume("no NAS folder has been chosen") }
        return destination
    }

    // MARK: Offload

    public func offload(_ candidates: [OffloadCandidate], execute: Bool = false,
                        progress: (@Sendable (OffloadProgress) -> Void)? = nil) async -> OffloadReport {
        let started = Date()
        let check = checkDestination()
        guard case .ready = check else {
            let results = candidates.map {
                OffloadItemResult(candidate: $0, status: .failed(check.message), payloadBytes: 0, copySeconds: 0)
            }
            return OffloadReport(dryRun: !execute, destination: check, results: results, duration: 0)
        }
        let localBefore = VolumeInfo.availableBytes(at: context.home) ?? 0
        var results: [OffloadItemResult] = []
        let weights = candidates.map { max(1, $0.size ?? 1) }
        let totalWeight = Double(weights.reduce(0, +))
        var doneWeight: Int64 = 0

        for (i, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                results.append(OffloadItemResult(candidate: candidate, status: .cancelled, payloadBytes: 0, copySeconds: 0))
                continue
            }
            let base = Double(doneWeight) / totalWeight
            let span = Double(weights[i]) / totalWeight
            let reporter = ProgressReporter(index: i, count: candidates.count, name: candidate.displayName,
                                            base: base, span: span, sink: progress)
            reporter.phase(.checking, total: 0)
            let result = await offloadOne(candidate, execute: execute, reporter: reporter)
            results.append(result)
            doneWeight += weights[i]
        }

        if execute {
            appendHistory(results, localBefore: localBefore)
        }
        return OffloadReport(dryRun: !execute, destination: check, results: results,
                             duration: Date().timeIntervalSince(started))
    }

    private func offloadOne(_ candidate: OffloadCandidate, execute: Bool, reporter: ProgressReporter) async -> OffloadItemResult {
        var result = OffloadItemResult(candidate: candidate, status: .wouldOffload, payloadBytes: 0, copySeconds: 0)
        // 1. Re-resolve and re-validate; walk the source.
        let walk: (nodes: [SourceNode], skipped: [String])
        let format: OffloadFormat
        do {
            try await revalidate(candidate)
            walk = try SourceTree.walk(candidate.path)
            format = Self.format(for: candidate.path, nodes: walk.nodes)
        } catch let e as OffloadError {
            result.status = .skipped(e.description)
            return result
        } catch {
            result.status = .skipped(error.localizedDescription)
            return result
        }
        let estimate = Self.estimatePayload(walk.nodes, format: format)
        result.payloadBytes = estimate

        // 2. Share still there, with room for it.
        let status: VolumeStatus
        switch checkDestination() {
        case .ready(let s): status = s
        case let other:
            result.status = .failed(other.message)
            return result
        }
        if status.isICloud, estimate > ICloudDrive.maxFileBytes {
            result.status = .failed(OffloadError.refused("iCloud Drive doesn't take files over \(ByteFormat.string(ICloudDrive.maxFileBytes)); this one would be \(ByteFormat.string(estimate))").description)
            return result
        }
        let needed = estimate + max(256_000_000, estimate / 50)
        if status.availableBytes < needed {
            result.status = .failed(OffloadError.insufficientSpace(needed: needed, available: status.availableBytes).description)
            return result
        }
        guard execute else { return result }

        // 3. Copy → verify → manifest → rename into place.
        let manifest: OffloadManifest
        do {
            let copied = try copyAndVerify(candidate, nodes: walk.nodes, skipped: walk.skipped, format: format,
                                           estimate: estimate, share: status, reporter: reporter)
            manifest = copied.manifest
            result.payloadBytes = manifest.payloadBytes
            result.copySeconds = copied.copySeconds
        } catch {
            let failed = (error as? FailedCopy) ?? FailedCopy(underlying: (error as? OffloadError) ?? .io(error.localizedDescription))
            result.status = failed.underlying == .cancelled ? .cancelled : .failed(failed.underlying.description)
            result.partialNote = failed.partialNote
            return result
        }

        // 4. Local manifest + record. If that fails the NAS copy is complete, but the original stays.
        var record = OffloadRecord(manifest: manifest, original: .kept("not moved to the Trash yet"), restores: [],
                                   importedFromShare: false)
        do {
            try store.saveManifest(manifest)
            try store.save(record)
        } catch {
            record.original = .kept("couldn't write the local manifest (\(error.localizedDescription)); the original was left in place")
            result.status = .offloaded(trashed: false)
            result.record = record
            return result
        }

        // 5. Only now: re-validate, make sure the original didn't change while copying, move it to the Trash.
        reporter.phase(.trashing, total: 0)
        do {
            try await revalidate(candidate)
            let again = try SourceTree.walk(candidate.path)
            let diff = SourceTree.differences(walk.nodes, again.nodes)
            if !diff.isEmpty { throw OffloadError.sourceChanged(diff.joined(separator: "; ")) }
            try remover.trash(candidate.path)
            record.original = .trashed(Date())
        } catch {
            let message = (error as? OffloadError)?.description ?? (error as? PathValidationError).map { "refused: \($0.description)" }
                ?? error.localizedDescription
            record.original = .kept(message)
        }
        try? store.save(record)
        result.record = record
        if case .trashed = record.original { result.status = .offloaded(trashed: true) } else { result.status = .offloaded(trashed: false) }
        return result
    }

    /// An error during copy/verify plus what became of the partial copy.
    struct FailedCopy: Error {
        var underlying: OffloadError
        var partialNote: String?
    }

    private func copyAndVerify(_ candidate: OffloadCandidate, nodes: [SourceNode], skipped: [String], format: OffloadFormat,
                               estimate: Int64, share: VolumeStatus, reporter: ProgressReporter) throws -> (manifest: OffloadManifest, copySeconds: Double) {
        let date = Date()
        let name = candidate.path.lastPathComponent
        let claimed: (partial: URL, final: URL)
        do {
            claimed = try OffloadLayout.claim(destination: try requireDestination(), kind: candidate.kind, name: name, date: date)
        } catch {
            throw FailedCopy(underlying: (error as? OffloadError) ?? .io(error.localizedDescription))
        }
        do {
            let payloadName = format == .tar ? SMBName.safe(name, maxBytes: 116) + ".tar" : SMBName.safe(name)
            let payloadURL = claimed.partial.appending(path: payloadName)
            let payloadPath = payloadURL.path(percentEncoded: false)

            // Copy.
            reporter.phase(.copying, total: estimate)
            let copyStart = Date()
            var lastMountCheck: Int64 = 0
            let sink = try PayloadSink(path: payloadPath) { written in
                if Task.isCancelled { throw OffloadError.cancelled }
                if let fault = self.hooks.writeFault?(written) { throw fault }
                if written - lastMountCheck >= self.mountCheckInterval {
                    lastMountCheck = written
                    try self.ensureSameShare(share)
                }
                reporter.bytes(written, weight: 0.5)
            }
            let entries: [OffloadEntry]
            var fileXattrs: [String: Data]?
            do {
                switch format {
                case .tar:
                    entries = try writeTar(root: candidate.path, nodes: nodes, sink: sink)
                case .file:
                    let attrs = XAttr.read(candidate.path.path(percentEncoded: false))
                    fileXattrs = attrs.isEmpty ? nil : Dictionary(attrs.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
                    entries = [try writeFile(root: candidate.path, node: nodes[0], attrs: attrs, sink: sink)]
                }
            } catch {
                sink.abort()
                throw error
            }
            let payloadSHA = try sink.finish()
            let payloadBytes = sink.written
            let copySeconds = Date().timeIntervalSince(copyStart)
            hooks.afterPayloadWritten?(payloadURL)
            try ensureSameShare(share)

            // Verify by reading the NAS copy back (uncached).
            reporter.phase(.verifying, total: payloadBytes)
            try verify(payloadPath: payloadPath, format: format, entries: entries, payloadBytes: payloadBytes,
                       payloadSHA: payloadSHA, share: share, reporter: reporter)
            try ensureSameShare(share)

            // Manifest next to the payload, read back, then rename the folder into place.
            reporter.phase(.finishing, total: 0)
            let manifest = OffloadManifest(
                version: OffloadManifest.currentVersion, id: UUID(), kind: candidate.kind, displayName: candidate.displayName,
                sourcePath: clean(candidate.path.path(percentEncoded: false)), sourceHost: Self.hostName, createdAt: date,
                format: format, payloadName: payloadName, payloadBytes: payloadBytes, payloadSHA256: payloadSHA,
                archivePath: clean(claimed.final.path(percentEncoded: false)),
                contentBytes: entries.reduce(0) { $0 + ($1.kind == .file ? $1.size : 0) },
                fileCount: entries.filter { $0.kind == .file }.count,
                directoryCount: entries.filter { $0.kind == .directory }.count,
                symlinkCount: entries.filter { $0.kind == .symlink }.count,
                checksumCapBytes: checksumCapBytes, skipped: skipped, fileXattrs: fileXattrs,
                restoreCommand: Self.restoreCommand(format: format, payload: claimed.final.appending(path: payloadName),
                                                    source: candidate.path),
                notes: candidate.restoreCommands.isEmpty ? [] : ["After restoring, reinstall dependencies: " + candidate.restoreCommands.joined(separator: " && ")],
                entries: entries)
            let manifestURL = claimed.partial.appending(path: "manifest.json")
            let data = try OffloadStore.encoder.encode(manifest)
            let msink = try PayloadSink(path: manifestURL.path(percentEncoded: false)) { _ in }
            try data.withUnsafeBytes { try msink.write($0) }
            _ = try msink.finish()
            let back = try PayloadSource(path: manifestURL.path(percentEncoded: false))
            let backData = try back.readBytes(data.count)
            guard try back.atEnd(), Data(backData) == data else { throw OffloadError.verification("manifest.json didn't read back identically") }
            try ensureSameShare(share)
            try Self.renameExclusive(claimed.partial, claimed.final)
            return (manifest, copySeconds)
        } catch {
            let underlying = (error as? OffloadError) ?? .io(error.localizedDescription)
            throw FailedCopy(underlying: underlying, partialNote: removePartial(claimed.partial, share: share))
        }
    }

    /// Removes our own incomplete `.partial` folder, but only while the same share is mounted.
    private func removePartial(_ partial: URL, share: VolumeStatus) -> String {
        let path = partial.path(percentEncoded: false)
        guard partial.lastPathComponent.hasSuffix(OffloadLayout.partialSuffix) else { return "left in place: \(path)" }
        guard (try? ensureSameShare(share)) != nil else {
            return "The share went away, so the incomplete copy couldn't be removed; it stays marked as incomplete (\(partial.lastPathComponent)) and can be removed from the Offloaded list later."
        }
        do {
            try FileManager.default.removeItem(at: partial)
            return "The incomplete copy on the NAS was removed."
        } catch {
            return "The incomplete copy couldn't be removed (\(error.localizedDescription)); it stays marked as incomplete at \(path)."
        }
    }

    func ensureSameShare(_ share: VolumeStatus) throws {
        let destination = try requireDestination()
        guard let now = probe.status(of: destination) else { throw OffloadError.shareChanged("\(destination.path) is gone") }
        guard now.isOffloadTarget, now.identity == share.identity else {
            throw OffloadError.shareChanged("\(destination.path) is no longer \(share.mountedFrom)")
        }
    }

    // MARK: Writing

    private func writeTar(root: URL, nodes: [SourceNode], sink: PayloadSink) throws -> [OffloadEntry] {
        let rootPath = root.path(percentEncoded: false)
        let rootName = root.lastPathComponent
        var entries: [OffloadEntry] = []
        entries.reserveCapacity(nodes.count)
        for node in nodes {
            let abs = node.rel.isEmpty ? rootPath : rootPath + "/" + node.rel
            let tarName = rootName + (node.rel.isEmpty ? "" : "/" + node.rel) + (node.type == .directory ? "/" : "")
            let attrs = XAttr.read(abs).filter { !$0.name.contains("=") }
            var entry = OffloadEntry(path: node.rel, kind: node.type, size: node.size, mode: node.mode, modified: node.modified,
                                     linkTarget: node.linkTarget, xattrCount: attrs.isEmpty ? nil : attrs.count,
                                     xattrDigest: XAttr.digest(attrs))
            switch node.type {
            case .directory:
                try sink.append(Tar.headers(name: tarName, type: .directory, size: 0, mode: node.mode, mtime: node.modified, xattrs: attrs))
            case .symlink:
                try sink.append(Tar.headers(name: tarName, type: .symlink, size: 0, mode: node.mode, mtime: node.modified,
                                            linkName: node.linkTarget ?? "", xattrs: attrs))
            case .file:
                try sink.append(Tar.headers(name: tarName, type: .file, size: node.size, mode: node.mode, mtime: node.modified, xattrs: attrs))
                let hashes = try copyContent(abs, size: node.size, into: sink)
                entry.sha256 = hashes.full
                entry.sampleSHA256 = hashes.sample
                try sink.append([UInt8](repeating: 0, count: Tar.padding(node.size)))
            }
            entries.append(entry)
        }
        try sink.append(Tar.end())
        return entries
    }

    private func writeFile(root: URL, node: SourceNode, attrs: [(name: String, value: Data)], sink: PayloadSink) throws -> OffloadEntry {
        var entry = OffloadEntry(path: "", kind: .file, size: node.size, mode: node.mode, modified: node.modified,
                                 xattrCount: attrs.isEmpty ? nil : attrs.count, xattrDigest: XAttr.digest(attrs))
        let hashes = try copyContent(root.path(percentEncoded: false), size: node.size, into: sink)
        entry.sha256 = hashes.full
        entry.sampleSHA256 = hashes.sample
        return entry
    }

    /// Streams one file into the sink, hashing it; fails if it isn't exactly the size the walk saw.
    private func copyContent(_ path: String, size: Int64, into sink: PayloadSink) throws -> (full: String, sample: String?) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError("can't open", path) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw OffloadError.sourceChanged("\(path) is no longer a file") }
        guard Int64(st.st_size) == size else { throw OffloadError.sourceChanged("\(path) changed size") }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: ioChunk, alignment: 16)
        defer { buffer.deallocate() }
        var full = SHA256()
        var sample = SampleHasher(size: size, enabled: size > checksumCapBytes)
        var offset: Int64 = 0
        while offset < size {
            let want = Int(min(Int64(ioChunk), size - offset))
            let n = Darwin.read(fd, buffer.baseAddress!, want)
            if n < 0 {
                if errno == EINTR { continue }
                throw posixError("read failed on", path)
            }
            if n == 0 { throw OffloadError.sourceChanged("\(path) got shorter while copying") }
            let chunk = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[0..<n])
            full.update(bufferPointer: chunk)
            sample.feed(chunk, at: offset)
            try sink.write(chunk)
            offset += Int64(n)
        }
        var extra: UInt8 = 0
        if Darwin.read(fd, &extra, 1) > 0 { throw OffloadError.sourceChanged("\(path) grew while copying") }
        return (full.finalize().hex, sample.result)
    }

    // MARK: Verification

    /// Reads the NAS copy back and compares it with what was written: every path, kind, size and symlink target,
    /// extended attributes, SHA-256 of every file up to the checksum cap (first + last 4 MiB above it), and the
    /// payload's own length and (when fully read) SHA-256.
    private func verify(payloadPath: String, format: OffloadFormat, entries: [OffloadEntry], payloadBytes: Int64,
                        payloadSHA: String, share: VolumeStatus, reporter: ProgressReporter) throws {
        var st = stat()
        guard stat(payloadPath, &st) == 0 else { throw posixError("can't read back", payloadPath) }
        guard Int64(st.st_size) == payloadBytes else {
            throw OffloadError.verification("the NAS copy is \(st.st_size) bytes, \(payloadBytes) were written")
        }
        var lastMountCheck: Int64 = 0
        let src = try PayloadSource(path: payloadPath) { read in
            if Task.isCancelled { throw OffloadError.cancelled }
            if read - lastMountCheck >= self.mountCheckInterval {
                lastMountCheck = read
                try self.ensureSameShare(share)
            }
            reporter.bytes(read, weight: 0.5)
        }
        switch format {
        case .file:
            guard let e = entries.first else { throw OffloadError.verification("no entry") }
            try verifyContent(src, entry: e, name: "the file")
        case .tar:
            let expected = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            var rootName: String?
            while let e = try Tar.next(src) {
                let rel = try Self.relativePath(e.name, rootName: &rootName)
                guard let x = expected[rel] else { throw OffloadError.verification("unexpected entry \(e.name)") }
                guard seen.insert(rel).inserted else { throw OffloadError.verification("\(e.name) appears twice") }
                let name = rel.isEmpty ? "the top folder" : rel
                guard Self.kind(e.type) == x.kind else { throw OffloadError.verification("\(name) has the wrong type") }
                guard XAttr.digest(e.xattrs) == x.xattrDigest else {
                    throw OffloadError.verification("extended attributes of \(name) differ")
                }
                switch x.kind {
                case .file:
                    guard e.size == x.size else { throw OffloadError.verification("\(name): \(e.size) bytes, expected \(x.size)") }
                    try verifyContent(src, entry: x, name: name)
                case .symlink:
                    guard e.linkName == x.linkTarget else { throw OffloadError.verification("\(name) points somewhere else") }
                    try src.skip(e.size)
                case .directory:
                    try src.skip(e.size)
                }
                try src.skip(Int64(Tar.padding(e.size)))
            }
            guard seen.count == expected.count else {
                let missing = Set(expected.keys).subtracting(seen).sorted().prefix(3).map { $0.isEmpty ? "." : $0 }
                throw OffloadError.verification("missing from the NAS copy: \(missing.joined(separator: ", "))")
            }
            guard try src.atEnd() else { throw OffloadError.verification("unexpected data after the end of the archive") }
        }
        if let sha = src.sha256, sha != payloadSHA {
            throw OffloadError.verification("the NAS copy's checksum differs from what was written")
        }
    }

    /// Full SHA-256 up to the cap, first + last 4 MiB above it.
    private func verifyContent(_ src: PayloadSource, entry: OffloadEntry, name: String) throws {
        if entry.size <= checksumCapBytes || entry.sampleSHA256 == nil {
            var h = SHA256()
            try src.read(entry.size) { h.update(bufferPointer: $0) }
            guard h.finalize().hex == entry.sha256 else { throw OffloadError.verification("checksum mismatch: \(name)") }
        } else {
            let (head, tail) = SampleHasher.ranges(size: entry.size)
            var h = SHA256()
            try src.read(head) { h.update(bufferPointer: $0) }
            try src.skip(entry.size - head - tail)
            try src.read(tail) { h.update(bufferPointer: $0) }
            guard h.finalize().hex == entry.sampleSHA256 else { throw OffloadError.verification("checksum mismatch: \(name)") }
        }
    }

    static func kind(_ tarType: UInt8) -> OffloadEntry.Kind? {
        switch tarType {
        case Tar.EntryType.file.rawValue: .file
        case Tar.EntryType.directory.rawValue: .directory
        case Tar.EntryType.symlink.rawValue: .symlink
        default: nil
        }
    }

    /// `<root>/<rel>` → `rel` ("" for the root), refusing absolute paths, `.`/`..` and a second top-level name.
    static func relativePath(_ name: String, rootName: inout String?) throws -> String {
        var trimmed = name
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.hasPrefix("/") else { throw OffloadError.verification("absolute path in archive: \(name)") }
        let comps = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = comps.first, !comps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw OffloadError.verification("unsafe path in archive: \(name)")
        }
        if let r = rootName, r != first { throw OffloadError.verification("second top-level item in archive: \(name)") }
        rootName = first
        return comps.dropFirst().joined(separator: "/")
    }

    // MARK: Restore

    /// Copies an offload back to where it came from (or into `folder`), verifies it, and only then moves it into place.
    /// Refuses to overwrite anything. Never deletes the NAS copy. Dry run unless `execute`.
    public func restore(_ record: OffloadRecord, into folder: URL? = nil, execute: Bool = false,
                        progress: (@Sendable (OffloadProgress) -> Void)? = nil) async -> RestoreResult {
        let source = URL(filePath: record.manifest.sourcePath)
        let parent = (folder ?? source.deletingLastPathComponent()).standardizedFileURL
        let target = parent.appending(path: source.lastPathComponent)
        var result = RestoreResult(record: record, target: target, error: nil, bytes: 0, seconds: 0, xattrFailures: 0)
        let reporter = ProgressReporter(index: 0, count: 1, name: record.manifest.displayName, base: 0, span: 1, sink: progress)
        reporter.phase(.checking, total: 0)
        let start = Date()
        var staging: URL?
        do {
            let manifest = try loadManifest(record)
            let archiveDir = URL(filePath: manifest.archivePath, directoryHint: .isDirectory)
            let check = DestinationCheck.check(archiveDir, probe: probe)
            guard case .ready(let share) = check else { throw OffloadError.notMounted(check.message) }
            let targetPath = target.path(percentEncoded: false)
            var st = stat()
            if lstat(targetPath, &st) == 0 { throw OffloadError.alreadyExists(targetPath) }
            if let mount = probe.status(of: parent), mount.isNetwork {
                throw OffloadError.refused("restore to a folder on this Mac, not onto a network share")
            }
            let fm = FileManager.default
            if !fm.fileExists(atPath: parent.path(percentEncoded: false)) {
                let home = context.home.path(percentEncoded: false)
                guard parent.path(percentEncoded: false).hasPrefix(home + "/") else {
                    throw OffloadError.refused("\(parent.path) doesn't exist")
                }
                if execute { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
            }
            if fm.fileExists(atPath: parent.path(percentEncoded: false)) {
                let free = VolumeInfo.availableBytes(at: parent) ?? 0
                var needed = manifest.contentBytes + max(200_000_000, manifest.contentBytes / 50)
                // An archive evicted to iCloud is downloaded onto this Mac again while it is read.
                if share.isICloud, let state = cloud.state(of: archiveDir.appending(path: manifest.payloadName)), !state.isLocal {
                    needed += manifest.payloadBytes
                }
                if free < needed { throw OffloadError.insufficientSpace(needed: needed, available: free) }
            }
            guard execute else { return result }

            let stage = parent.appending(path: ".majortom-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
            guard mkdir(stage.path(percentEncoded: false), 0o700) == 0 else { throw posixError("can't create", stage.path) }
            staging = stage
            let staged = stage.appending(path: source.lastPathComponent)
            reporter.phase(.restoring, total: manifest.payloadBytes)
            let payload = archiveDir.appending(path: manifest.payloadName).path(percentEncoded: false)
            var lastMountCheck: Int64 = 0
            let src = try PayloadSource(path: payload) { read in
                if Task.isCancelled { throw OffloadError.cancelled }
                if read - lastMountCheck >= self.mountCheckInterval {
                    lastMountCheck = read
                    guard let now = self.probe.status(of: archiveDir), now.identity == share.identity else {
                        throw OffloadError.shareChanged("\(archiveDir.path) went away")
                    }
                }
                reporter.bytes(read, weight: 1)
            }
            switch manifest.format {
            case .tar: result.xattrFailures = try extractTar(src, to: staged, manifest: manifest)
            case .file: result.xattrFailures = try extractFile(src, to: staged, manifest: manifest)
            }
            guard src.sha256 == manifest.payloadSHA256 else {
                throw OffloadError.verification("the NAS copy no longer matches its manifest checksum")
            }
            reporter.phase(.checkingRestore, total: 0)
            let walked = try SourceTree.walk(staged)
            try Self.compare(walked.nodes, with: manifest.entries)
            var st2 = stat()
            if lstat(targetPath, &st2) == 0 { throw OffloadError.alreadyExists(targetPath) }
            try Self.renameExclusive(staged, target)
            try? fm.removeItem(at: stage)
            staging = nil
            result.bytes = manifest.payloadBytes
            var updated = store.record(id: record.id) ?? record
            updated.restores.append(.init(date: Date(), path: targetPath))
            try? store.save(updated)
            result.record = updated
        } catch {
            result.error = (error as? OffloadError) ?? .io(error.localizedDescription)
        }
        if let stage = staging, stage.lastPathComponent.hasPrefix(".majortom-restore-") {
            try? FileManager.default.removeItem(at: stage)
        }
        result.seconds = Date().timeIntervalSince(start)
        return result
    }

    /// The NAS manifest is authoritative; the local copy is the fallback for its entries.
    func loadManifest(_ record: OffloadRecord) throws -> OffloadManifest {
        let nasURL = URL(filePath: record.manifest.manifestPath)
        if let data = try? Data(contentsOf: nasURL) {
            let m = try OffloadStore.decoder.decode(OffloadManifest.self, from: data)
            guard m.id == record.id else { throw OffloadError.manifest("the manifest on the NAS belongs to another offload") }
            return m
        }
        guard FileManager.default.fileExists(atPath: record.manifest.archivePath) else {
            throw OffloadError.notMounted("\(record.manifest.archivePath) isn't reachable")
        }
        if let local = store.manifest(id: record.id) { return local }
        throw OffloadError.manifest("manifest.json is missing on the NAS and on this Mac")
    }

    private func extractTar(_ src: PayloadSource, to base: URL, manifest: OffloadManifest) throws -> Int {
        let basePath = base.path(percentEncoded: false)
        let expected = Dictionary(manifest.entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var created = Set<String>()
        var dirs: [(path: String, entry: OffloadEntry, attrs: [(name: String, value: Data)])] = []
        var xattrFailures = 0
        var rootName: String?
        while let e = try Tar.next(src) {
            let rel = try Self.relativePath(e.name, rootName: &rootName)
            guard let x = expected[rel], Self.kind(e.type) == x.kind else {
                throw OffloadError.verification("\(e.name) isn't in the manifest")
            }
            if !rel.isEmpty {
                let parentRel = (rel as NSString).deletingLastPathComponent
                guard created.contains(parentRel) else {
                    throw OffloadError.verification("\(e.name) isn't inside a folder the archive created")
                }
            } else if x.kind == .directory {
                // fine: the top folder
            }
            let dest = rel.isEmpty ? basePath : basePath + "/" + rel
            switch x.kind {
            case .directory:
                guard mkdir(dest, 0o700) == 0 else { throw posixError("can't create", dest) }
                created.insert(rel)
                dirs.append((dest, x, e.xattrs))
                try src.skip(e.size)
            case .symlink:
                guard symlink(e.linkName, dest) == 0 else { throw posixError("can't create link", dest) }
                xattrFailures += XAttr.write(e.xattrs, to: dest)
                Self.setTimes(dest, x.modified)
                try src.skip(e.size)
            case .file:
                guard e.size == x.size else { throw OffloadError.verification("\(rel): size differs from the manifest") }
                try writeRestoredFile(src, to: dest, entry: x)
                xattrFailures += XAttr.write(e.xattrs, to: dest)
                Self.setTimes(dest, x.modified)
            }
            try src.skip(Int64(Tar.padding(e.size)))
        }
        guard try src.atEnd() else { throw OffloadError.verification("unexpected data after the end of the archive") }
        for d in dirs.reversed() {
            xattrFailures += XAttr.write(d.attrs, to: d.path)
            chmod(d.path, mode_t(d.entry.mode))
            Self.setTimes(d.path, d.entry.modified)
        }
        return xattrFailures
    }

    private func extractFile(_ src: PayloadSource, to dest: URL, manifest: OffloadManifest) throws -> Int {
        guard let entry = manifest.entries.first, entry.kind == .file else { throw OffloadError.manifest("no file entry") }
        let path = dest.path(percentEncoded: false)
        try writeRestoredFile(src, to: path, entry: entry)
        guard try src.atEnd() else { throw OffloadError.verification("the NAS copy is longer than the manifest says") }
        let attrs = (manifest.fileXattrs ?? [:]).map { (name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        let failures = XAttr.write(attrs, to: path)
        Self.setTimes(path, entry.modified)
        return failures
    }

    /// Writes exactly `entry.size` bytes from the archive, checking the full SHA-256 recorded at offload time.
    private func writeRestoredFile(_ src: PayloadSource, to path: String, entry: OffloadEntry) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError("can't create", path) }
        defer { close(fd) }
        var h = SHA256()
        try src.read(entry.size) { chunk in
            h.update(bufferPointer: chunk)
            var off = 0
            while off < chunk.count {
                let n = Darwin.write(fd, chunk.baseAddress! + off, chunk.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write failed on", path)
                }
                off += n
            }
        }
        guard h.finalize().hex == entry.sha256 else {
            throw OffloadError.verification("checksum mismatch restoring \(entry.path.isEmpty ? (path as NSString).lastPathComponent : entry.path)")
        }
        fchmod(fd, mode_t(entry.mode))
        guard fsync(fd) == 0 else { throw posixError("can't sync", path) }
    }

    /// The restored tree has exactly the manifest's paths, kinds, sizes and link targets.
    static func compare(_ nodes: [SourceNode], with entries: [OffloadEntry]) throws {
        let byPath = Dictionary(nodes.map { ($0.rel, $0) }, uniquingKeysWith: { a, _ in a })
        guard byPath.count == entries.count else {
            throw OffloadError.verification("restored \(byPath.count) entries, the manifest has \(entries.count)")
        }
        for e in entries {
            guard let n = byPath[e.path], n.type == e.kind else {
                throw OffloadError.verification("\(e.path.isEmpty ? "the item" : e.path) is missing after restore")
            }
            if e.kind == .file, n.size != e.size { throw OffloadError.verification("\(e.path): wrong size after restore") }
            if e.kind == .symlink, n.linkTarget != e.linkTarget { throw OffloadError.verification("\(e.path): wrong link target") }
        }
    }

    static func setTimes(_ path: String, _ date: Date) {
        let t = date.timeIntervalSince1970
        let ts = timespec(tv_sec: Int(t.rounded(.down)), tv_nsec: Int((t - t.rounded(.down)) * 1e9))
        var times = [ts, ts]
        utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// rename(2) that never replaces an existing item (falls back to check-then-rename where RENAME_EXCL isn't supported).
    static func renameExclusive(_ from: URL, _ to: URL) throws {
        let a = from.path(percentEncoded: false), b = to.path(percentEncoded: false)
        if renamex_np(a, b, UInt32(RENAME_EXCL)) == 0 { return }
        let err = errno
        if err == EEXIST { throw OffloadError.alreadyExists(b) }
        guard err == ENOTSUP || err == EINVAL else { throw posixError("can't rename to", b, err) }
        var st = stat()
        if lstat(b, &st) == 0 { throw OffloadError.alreadyExists(b) }
        guard rename(a, b) == 0 else { throw posixError("can't rename to", b) }
    }

    // MARK: Share housekeeping

    /// Finished offloads on the share this Mac has no record of (e.g. after reinstalling) become local records, so
    /// they show up in the Offloaded list and can be restored. Nothing on the share is changed.
    public func importFromShare() -> [OffloadRecord] {
        guard checkDestination().isReady, let destination else { return [] }
        var out: [OffloadRecord] = []
        for url in OffloadLayout.manifests(in: destination) {
            guard let data = try? Data(contentsOf: url),
                  var m = try? OffloadStore.decoder.decode(OffloadManifest.self, from: data),
                  store.record(id: m.id) == nil else { continue }
            m.archivePath = clean(url.deletingLastPathComponent().path(percentEncoded: false))
            let r = OffloadRecord(manifest: m, original: .kept("found on the NAS (offloaded from \(m.sourceHost))"),
                                  restores: [], importedFromShare: true)
            do {
                try store.saveManifest(m)
                try store.save(r)
                out.append(r)
            } catch { continue }
        }
        return out
    }

    /// Deletes the `.partial` folders interrupted offloads left on the share — only those, and only while it's mounted.
    public func removeIncompleteCopies() -> (removed: Int, failed: [String]) {
        guard checkDestination().isReady, let destination else { return (0, ["the share isn't mounted"]) }
        var removed = 0
        var failed: [String] = []
        for p in OffloadLayout.partials(in: destination) where p.lastPathComponent.hasSuffix(OffloadLayout.partialSuffix) {
            do {
                try FileManager.default.removeItem(at: p)
                removed += 1
            } catch {
                failed.append("\(p.path): \(error.localizedDescription)")
            }
        }
        return (removed, failed)
    }

    // MARK: Candidates and validation

    /// Fresh check that this candidate is still something Major Tom would offer, and that its path passes the same
    /// validation as a clean (inside home, not protected, not a volume or configured root, no symlink escape).
    func revalidate(_ c: OffloadCandidate) async throws {
        let validator = PathValidator(context: context)
        let settings = context.settings
        switch c.kind {
        case .project:
            let roots = settings.expandedProjectRoots(home: context.home).map(\.standardizedFileURL)
            guard roots.contains(where: { isStrictlyInside(c.path.path, $0.path) }) else {
                throw OffloadError.refused("not inside a configured project folder")
            }
            guard !settings.pinnedProjects.contains(c.path.path) else { throw OffloadError.refused("project is pinned") }
            guard !settings.ignoredProjects.contains(c.path.path) else { throw OffloadError.refused("project is hidden") }
            guard let p = await ProjectScanner(context: context, git: git).analyze(projectAt: c.path) else {
                throw OffloadError.refused("no longer a project")
            }
            guard p.isStale(afterDays: settings.staleAfterDays) else { throw OffloadError.refused("project is active again") }
            do { try validator.validate(c.path, bases: roots, allowRepositoryRoot: true) } catch {
                throw OffloadError.refused(error.description)
            }
        case .xcodeArchive, .file:
            let allowed = c.kind == .file ? Self.fileRuleIDs : Self.archiveRuleIDs
            guard let id = c.ruleID, allowed.contains(id), let rule = rules.first(where: { $0.id == id }) else {
                throw OffloadError.refused("unknown source rule")
            }
            let items = await rule.resolveItems(context).items
            guard let item = items.first(where: { $0.path?.standardizedFileURL.path == c.path.path }) else {
                throw OffloadError.refused("no longer listed by \(rule.title)")
            }
            guard !item.isProtected else { throw OffloadError.refused("protected") }
            if id == "large-files", let used = item.lastUsed ?? DiskSizer.lastUsed(of: c.path),
               Date().timeIntervalSince(used) < Double(Self.coldFileDays) * 86400 {
                throw OffloadError.refused("used in the last \(Self.coldFileDays) days")
            }
            let bases = rule.baseDirectories(context)
            do {
                try validator.validate(c.path, bases: bases)
                if rule.isTrashOnly { try validator.validateUserFile(c.path, bases: bases) }
            } catch {
                throw OffloadError.refused(error.description)
            }
        }
    }

    /// What could go to the NAS now: stale projects, Xcode archives, and large/old files that haven't been used for a while.
    /// `projects` lets the caller pass an existing project scan.
    public func candidates(projects: [Project]? = nil) async -> [OffloadCandidate] {
        let settings = context.settings
        var out: [OffloadCandidate] = []
        let found: [Project]
        if let projects { found = projects } else {
            found = await ProjectScanner.sized(await ProjectScanner(context: context, git: git).discover())
        }
        for p in found where !settings.pinnedProjects.contains(p.path.path) && !settings.ignoredProjects.contains(p.path.path)
            && p.isStale(afterDays: settings.staleAfterDays) {
            out.append(OffloadCandidate(
                kind: .project, path: p.path, displayName: p.relativePath, lastUsed: p.lastActivity,
                strippableBytes: p.strippableSize,
                strippableDirs: p.strippable.map(\.relativePath), warnings: p.warnings, restoreCommands: p.restoreCommands))
        }
        // A project folder that contains other projects (e.g. a plain folder holding several repos) archives them too.
        let projectPaths = out.map(\.path.path)
        for i in out.indices {
            let inside = projectPaths.filter { isStrictlyInside($0, out[i].path.path) }.count
            if inside > 0 {
                out[i].note = "contains \(inside) other listed project\(inside == 1 ? "" : "s"), which go into its archive too"
            }
        }
        for rule in rules where Self.archiveRuleIDs.contains(rule.id) || Self.fileRuleIDs.contains(rule.id) {
            let kind: OffloadKind = Self.archiveRuleIDs.contains(rule.id) ? .xcodeArchive : .file
            for item in await rule.resolveItems(context).items where item.isCleanable {
                guard let path = item.path else { continue }
                if kind == .xcodeArchive, path.pathExtension != "xcarchive" { continue }
                let used = item.lastUsed ?? DiskSizer.lastUsed(of: path)
                if rule.id == "large-files", let used, Date().timeIntervalSince(used) < Double(Self.coldFileDays) * 86400 { continue }
                if out.contains(where: { $0.path == path.standardizedFileURL }) { continue }
                out.append(OffloadCandidate(kind: kind, path: path, displayName: item.displayName, size: item.size,
                                            lastUsed: used, note: item.note, ruleID: rule.id))
            }
        }
        // Sizes (allocated, what the Trash frees once emptied).
        let tracker = InodeTracker()
        for i in out.indices where out[i].size == nil {
            out[i].size = await DiskSizer.size(of: out[i].path, tracker: tracker)?.allocatedBytes
        }
        return out
    }

    // MARK: Helpers

    static func format(for path: URL, nodes: [SourceNode]) -> OffloadFormat {
        guard nodes.count == 1, nodes[0].type == .file else { return .tar }
        let attrBytes = XAttr.read(path.path(percentEncoded: false)).reduce(0) { $0 + $1.value.count }
        return attrBytes <= 1_000_000 ? .file : .tar
    }

    static func estimatePayload(_ nodes: [SourceNode], format: OffloadFormat) -> Int64 {
        guard format == .tar else { return nodes.first?.size ?? 0 }
        return nodes.reduce(Int64(1024)) { $0 + Int64(Tar.block) * 2 + $1.size + Int64(Tar.padding($1.size)) }
    }

    static func restoreCommand(format: OffloadFormat, payload: URL, source: URL) -> String {
        let p = shellQuote(clean(payload.path(percentEncoded: false)))
        switch format {
        case .tar:
            let parent = shellQuote(clean(source.deletingLastPathComponent().path(percentEncoded: false)))
            return "mkdir -p \(parent) && tar -xkpf \(p) -C \(parent)"
        case .file:
            return "cp -n \(p) \(shellQuote(clean(source.path(percentEncoded: false))))"
        }
    }

    static var hostName: String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "this Mac" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func appendHistory(_ results: [OffloadItemResult], localBefore: Int64) {
        let attempted = results.filter { if case .offloaded = $0.status { true } else if case .failed = $0.status { true } else { false } }
        guard !attempted.isEmpty else { return }
        let reclaimed = (VolumeInfo.availableBytes(at: context.home) ?? 0) - localBefore
        let items = attempted.map { r -> HistoryEntry.ItemRecord in
            var error: String?
            var ok = false
            switch r.status {
            case .offloaded(let trashed):
                ok = trashed
                if !trashed, case .kept(let why)? = r.record?.original { error = "copied to the NAS; original kept: \(why)" }
            case .failed(let e): error = e
            default: break
            }
            return HistoryEntry.ItemRecord(ruleID: "offload:" + r.candidate.kind.rawValue, itemID: r.candidate.id,
                                           displayName: r.candidate.displayName, path: r.candidate.path.path,
                                           method: "offload to NAS, then move to Trash", estimatedBytes: r.candidate.size,
                                           succeeded: ok, error: error)
        }
        let estimate = attempted.filter { $0.status == .offloaded(trashed: true) }.reduce(Int64(0)) { $0 + ($1.candidate.size ?? 0) }
        let entry = HistoryEntry(id: UUID(), date: Date(), ruleIDs: Array(Set(items.map(\.ruleID))).sorted(), items: items,
                                 estimatedBytes: estimate, reclaimedBytes: reclaimed)
        try? history.append(entry)
    }
}

/// Head and tail sample hash for files over the checksum cap.
struct SampleHasher {
    let size: Int64
    let enabled: Bool
    private var hasher = SHA256()
    private let head: Int64
    private let tailStart: Int64

    init(size: Int64, enabled: Bool) {
        self.size = size
        self.enabled = enabled
        let (h, t) = Self.ranges(size: size)
        head = h
        tailStart = size - t
    }

    static func ranges(size: Int64) -> (head: Int64, tail: Int64) {
        let head = min(sampleBytes, size)
        let tail = min(sampleBytes, size - head)
        return (head, tail)
    }

    mutating func feed(_ chunk: UnsafeRawBufferPointer, at offset: Int64) {
        guard enabled else { return }
        let end = offset + Int64(chunk.count)
        for (lo, hi) in [(Int64(0), head), (tailStart, size)] {
            let a = max(lo, offset), b = min(hi, end)
            if a < b { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: chunk[Int(a - offset)..<Int(b - offset)])) }
        }
    }

    var result: String? { enabled ? hasher.finalize().hex : nil }
}

/// Turns byte counts into throttled `OffloadProgress` updates.
final class ProgressReporter: @unchecked Sendable {
    let index: Int, count: Int, name: String, base: Double, span: Double
    let sink: (@Sendable (OffloadProgress) -> Void)?
    private var phase: OffloadProgress.Phase = .checking
    private var total: Int64 = 0
    private var phaseStart = Date()
    private var lastSent = Date.distantPast
    private var phaseOffset = 0.0

    init(index: Int, count: Int, name: String, base: Double, span: Double, sink: (@Sendable (OffloadProgress) -> Void)?) {
        self.index = index
        self.count = count
        self.name = name
        self.base = base
        self.span = span
        self.sink = sink
    }

    func phase(_ p: OffloadProgress.Phase, total: Int64) {
        if phase == .copying, p == .verifying { phaseOffset = 0.5 }
        if p == .finishing || p == .trashing || p == .checkingRestore { phaseOffset = 1 }
        phase = p
        self.total = total
        phaseStart = Date()
        send(0, weight: 0, force: true)
    }

    func bytes(_ done: Int64, weight: Double) { send(done, weight: weight, force: false) }

    private func send(_ done: Int64, weight: Double, force: Bool) {
        guard let sink else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastSent) >= 0.1 || (total > 0 && done >= total) else { return }
        lastSent = now
        let elapsed = now.timeIntervalSince(phaseStart)
        let within = total > 0 ? min(1, Double(done) / Double(total)) * weight : 0
        sink(OffloadProgress(itemIndex: index, itemCount: count, itemName: name, phase: phase, bytesDone: done, bytesTotal: total,
                             overallFraction: min(1, base + span * min(1, phaseOffset + within)),
                             bytesPerSecond: elapsed > 0.2 && done > 0 ? Double(done) / elapsed : nil))
    }
}
