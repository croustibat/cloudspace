import Foundation
import MajorTomCore

/// The offload sheet: review (dry run) → copying/verifying with progress → per-item result.
public struct OffloadSession: Sendable {
    public enum Phase: Sendable {
        case reviewing(OffloadReport?)
        case running(OffloadProgress?, cancelling: Bool)
        case finished(OffloadReport)
    }

    public var candidates: [OffloadCandidate]
    public var phase: Phase

    public var estimatedBytes: Int64 { candidates.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Confirm is possible once the dry run says the share is ready and at least one item can go.
    public var canConfirm: Bool {
        guard case .reviewing(let report?) = phase, report.destination.isReady else { return false }
        return report.results.contains { $0.status == .wouldOffload }
    }

    public var isRunning: Bool { if case .running = phase { true } else { false } }
}

/// The restore sheet: review (dry run) → copying back with progress → result.
public struct RestoreSession: Sendable {
    public enum Phase: Sendable {
        case reviewing(RestoreResult?)
        case running(OffloadProgress?, cancelling: Bool)
        case finished(RestoreResult)
    }

    public var record: OffloadRecord
    /// Nil = the original location.
    public var folder: URL?
    public var phase: Phase

    public var canConfirm: Bool {
        guard case .reviewing(let r?) = phase else { return false }
        return r.succeeded
    }

    public var isRunning: Bool { if case .running = phase { true } else { false } }
}

/// NAS offload (M6). Review tier: never part of Quick clean; nothing happens without confirming in the offload sheet.
extension GroundControlModel {
    // MARK: Destination

    /// The chosen NAS folder; nil until the user picks one (the Offload view then asks for it).
    public var offloadDestination: URL? { settings.offloadDestinationURL }

    var offloadEngine: OffloadEngine { environment.offloadEngine(settings: settings) }

    /// Re-checks the share in the background (a sleeping NAS can make file system calls on its mount slow).
    public func refreshDestination() {
        Task { await refreshDestinationNow() }
    }

    /// Re-checks the share; while it's mounted, picks up offloads found on it, incomplete copies, and which
    /// offloads are reachable. All share I/O happens off the main actor.
    public func refreshDestinationNow() async {
        let engine = offloadEngine
        let (check, records, partials, reachable) = await Task.detached {
            let check = engine.checkDestination()
            guard check.isReady else { return (check, engine.store.records(), [URL](), Set<UUID>()) }
            _ = engine.importFromShare()
            let records = engine.store.records()
            let fm = FileManager.default
            let reachable = Set(records.filter { fm.fileExists(atPath: $0.manifest.payloadPath) }.map(\.id))
            return (check, records, engine.destination.map { OffloadLayout.partials(in: $0) } ?? [], reachable)
        }.value
        destinationCheck = check
        offloadRecords = records
        incompleteCopies = partials
        reachableOffloads = reachable
        if check.status?.isICloud == true { await refreshEvictionPreview() } else { evictionPreview = nil }
    }

    /// Local records only (no share access).
    public func reloadOffloadRecords() {
        offloadRecords = environment.offloads.records()
    }

    public func setOffloadDestination(_ url: URL?) {
        updateSettings { $0.offloadDestination = url?.standardizedFileURL.path(percentEncoded: false) }
        refreshDestination()
    }

    public func setChecksumCapMB(_ mb: Int) {
        updateSettings { $0.offloadChecksumCapMB = max(1, mb) }
    }

    // MARK: Candidates

    /// Stale projects (from the project scan when there is one), Xcode Archives and cold large/old files.
    public func scanOffloadCandidates() async {
        offloadCandidatesState = .scanning(completed: 0, total: 0)
        let start = Date()
        await refreshDestinationNow()
        let engine = offloadEngine
        let projects: [Project]? = projectsSized ? visibleProjects : nil
        let found = await Task.detached { await engine.candidates(projects: projects) }.value
        offloadCandidates = found.sorted {
            $0.kind != $1.kind ? OffloadKind.allCases.firstIndex(of: $0.kind)! < OffloadKind.allCases.firstIndex(of: $1.kind)!
                : ($0.size ?? 0) > ($1.size ?? 0)
        }
        let ids = Set(found.map(\.id))
        checkedOffloads = checkedOffloads.filter(ids.contains)
        offloadCandidatesState = .done(at: Date(), duration: Date().timeIntervalSince(start))
    }

    public var isScanningOffloadCandidates: Bool { if case .scanning = offloadCandidatesState { true } else { false } }

    public func offloadCandidates(kind: OffloadKind) -> [OffloadCandidate] { offloadCandidates.filter { $0.kind == kind } }

    public var offloadCandidateTotal: Int64 { offloadCandidates.reduce(0) { $0 + ($1.size ?? 0) } }

    public func isOffloadChecked(_ c: OffloadCandidate) -> Bool { checkedOffloads.contains(c.id) }

    public func setOffloadChecked(_ on: Bool, _ c: OffloadCandidate) {
        if on { checkedOffloads.insert(c.id) } else { checkedOffloads.remove(c.id) }
    }

    public var checkedOffloadCandidates: [OffloadCandidate] { offloadCandidates.filter { checkedOffloads.contains($0.id) } }

    /// "Hibernate first": the normal hibernation review for this project, so its dependencies aren't copied.
    public func hibernateBeforeOffload(_ c: OffloadCandidate) async {
        guard c.kind == .project else { return }
        if !projectsSized { await scanProjects() }
        await reviewHibernation(paths: [c.path.path])
    }

    // MARK: Offload flow

    /// Opens the offload sheet for the checked candidates (or `candidates`) and dry-runs it.
    public func reviewOffload(_ candidates: [OffloadCandidate]? = nil) async {
        let list = candidates ?? checkedOffloadCandidates
        guard !list.isEmpty, offloadSession == nil, restoreSession == nil else { return }
        offloadSession = OffloadSession(candidates: list, phase: .reviewing(nil))
        let engine = offloadEngine
        let report = await Task.detached { await engine.offload(list, execute: false) }.value
        guard case .reviewing = offloadSession?.phase else { return }
        offloadSession?.phase = .reviewing(report)
        destinationCheck = report.destination
    }

    /// The user confirmed: copy → verify → manifest → Trash, item by item, with progress.
    public func confirmOffload() {
        guard let session = offloadSession, session.canConfirm, case .reviewing(let dry?) = session.phase else { return }
        // Only what the dry run accepted.
        let accepted = Set(dry.results.filter { $0.status == .wouldOffload }.map(\.id))
        let list = session.candidates.filter { accepted.contains($0.id) }
        offloadSession?.phase = .running(nil, cancelling: false)
        let engine = offloadEngine
        let (stream, continuation) = AsyncStream<OffloadProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached {
            let report = await engine.offload(list, execute: true, progress: { continuation.yield($0) })
            continuation.finish()
            return report
        }
        offloadTask = Task {
            await withTaskCancellationHandler {
                for await p in stream {
                    if case .running(_, let cancelling) = offloadSession?.phase {
                        offloadSession?.phase = .running(p, cancelling: cancelling)
                    }
                }
            } onCancel: {
                work.cancel()
            }
            let report = await work.value
            offloadSession?.phase = .finished(report)
            await afterOffload(report)
        }
    }

    /// Stops after the current chunk; the item being copied is abandoned and its original left in place.
    public func cancelOffload() {
        guard case .running(let p, _) = offloadSession?.phase else { return }
        offloadSession?.phase = .running(p, cancelling: true)
        offloadTask?.cancel()
    }

    public func dismissOffload() {
        if offloadSession?.isRunning == true { return }
        offloadSession = nil
    }

    private func afterOffload(_ report: OffloadReport) async {
        let done = Set(report.results.filter { if case .offloaded = $0.status { true } else { false } }.map(\.id))
        checkedOffloads.subtract(done)
        reloadHistory()
        refreshDisk()
        await refreshDestinationNow()
        guard !done.isEmpty else { return }
        offloadCandidates.removeAll { done.contains($0.id) && !FileManager.default.fileExists(atPath: $0.path.path) }
        if report.results.contains(where: { $0.candidate.kind == .project && done.contains($0.id) }) { await scanProjects() }
        let ruleIDs = Set(report.results.compactMap { done.contains($0.id) ? $0.candidate.ruleID : nil })
        await scan(ruleIDs: Array(ruleIDs).filter { rule(id: $0) != nil })
    }

    // MARK: Restore flow

    public func reviewRestore(_ record: OffloadRecord, into folder: URL? = nil) async {
        guard restoreSession == nil, offloadSession == nil else { return }
        restoreSession = RestoreSession(record: record, folder: folder, phase: .reviewing(nil))
        let engine = offloadEngine
        let result = await Task.detached { await engine.restore(record, into: folder, execute: false) }.value
        guard case .reviewing = restoreSession?.phase else { return }
        restoreSession?.phase = .reviewing(result)
    }

    public func confirmRestore() {
        guard let session = restoreSession, session.canConfirm else { return }
        restoreSession?.phase = .running(nil, cancelling: false)
        let engine = offloadEngine
        let (stream, continuation) = AsyncStream<OffloadProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached {
            let r = await engine.restore(session.record, into: session.folder, execute: true, progress: { continuation.yield($0) })
            continuation.finish()
            return r
        }
        offloadTask = Task {
            await withTaskCancellationHandler {
                for await p in stream {
                    if case .running(_, let cancelling) = restoreSession?.phase {
                        restoreSession?.phase = .running(p, cancelling: cancelling)
                    }
                }
            } onCancel: {
                work.cancel()
            }
            let result = await work.value
            restoreSession?.phase = .finished(result)
            await refreshDestinationNow()
            if result.succeeded {
                switch result.record.manifest.kind {
                case .project: await scanProjects()
                case .xcodeArchive, .file: await scan(ruleIDs: rules.filter { OffloadEngine.archiveRuleIDs.contains($0.id) || OffloadEngine.fileRuleIDs.contains($0.id) }.map(\.id))
                }
            }
        }
    }

    public func cancelRestore() {
        guard case .running(let p, _) = restoreSession?.phase else { return }
        restoreSession?.phase = .running(p, cancelling: true)
        offloadTask?.cancel()
    }

    public func dismissRestore() {
        if restoreSession?.isRunning == true { return }
        restoreSession = nil
    }

    /// Removes the `.partial` folders interrupted offloads left on the share (never anything else).
    public func removeIncompleteCopies() async {
        let engine = offloadEngine
        let r = await Task.detached { engine.removeIncompleteCopies() }.value
        offloadMessage = r.failed.isEmpty
            ? "Removed \(r.removed) incomplete cop\(r.removed == 1 ? "y" : "ies") from the NAS."
            : "Removed \(r.removed); couldn't remove: \(r.failed.joined(separator: "; "))"
        await refreshDestinationNow()
    }

    // MARK: iCloud Drive

    /// The destination is a folder in iCloud Drive (copies land on this Mac first and are evicted once uploaded).
    public var destinationIsICloud: Bool { destinationCheck.status?.isICloud ?? false }

    /// What `freeLocalCopies()` would do right now (no changes).
    public func refreshEvictionPreview() async {
        let engine = offloadEngine
        evictionPreview = await Task.detached { engine.evictLocalCopies(execute: false) }.value
    }

    /// Evicts the local copy of every offloaded archive macOS has finished uploading to iCloud Drive. Archives still
    /// uploading are left alone; nothing is deleted.
    public func freeLocalCopies() async {
        let engine = offloadEngine
        let report = await Task.detached { engine.evictLocalCopies(execute: true) }.value
        var parts: [String] = []
        if report.evictedCount > 0 {
            parts.append("Freed the local copy of \(report.evictedCount) archive\(report.evictedCount == 1 ? "" : "s") (\(ByteFormat.string(report.evictableBytes))); they stay in iCloud Drive.")
        }
        if report.waitingForUpload > 0 {
            parts.append("\(report.waitingForUpload) still uploading to iCloud — try again later.")
        }
        let failed = report.results.compactMap { r -> String? in
            if case .failed(let e) = r.status { return "\(r.record.manifest.displayName): \(e)" }
            return nil
        }
        if !failed.isEmpty { parts.append("Couldn't free: " + failed.joined(separator: "; ")) }
        offloadMessage = parts.isEmpty ? "No local copies to free." : parts.joined(separator: " ")
        reloadHistory()
        refreshDisk()
        await refreshEvictionPreview()
    }

    // MARK: Fixture-only automation

    /// `--demo offload-review|offload|offload-running|restore-review|restore` (fixture only): selects the fixture
    /// candidates and drives the sheets for snapshots and end-to-end checks.
    func runOffloadDemo(_ step: String) async {
        guard environment.isFixture else { return }
        await scanProjectsIfNeeded()
        await scanOffloadCandidates()
        checkedOffloads = Set(offloadCandidates.map(\.id))
        if step.hasPrefix("restore") {
            await reviewOffload()
            confirmOffload()
            await offloadTask?.value
            dismissOffload()
            guard let record = offloadRecords.first(where: { $0.manifest.kind == .project }) ?? offloadRecords.first else { return }
            await reviewRestore(record)
            if step == "restore" {
                confirmRestore()
                await offloadTask?.value
            }
            return
        }
        await reviewOffload()
        switch step {
        case "offload":
            confirmOffload()
            await offloadTask?.value
        case "offload-running":
            confirmOffload()
            try? await Task.sleep(for: .seconds(2.5))
        default:
            break
        }
    }
}
