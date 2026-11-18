import Darwin
import Foundation
import Testing
@testable import MajorTomCore

/// Offload to iCloud Drive against temp folders: the "iCloud Drive" is `<fixture>/iCloud`, reported as an iCloud folder
/// on the local disk by `FakeVolumeProbe(iCloud: true)`; upload state and eviction come from `FakeCloudStorage`.
@Suite("iCloud Drive offload")
struct ICloudOffloadTests {
    final class World {
        let fx: Fixture
        let drive: URL
        let probe: FakeVolumeProbe
        let cloud = FakeCloudStorage()
        let remover: RecordingRemover
        let settings: Settings

        init() throws {
            fx = try Fixture()
            drive = try fx.dir("iCloud", in: fx.root)
            probe = FakeVolumeProbe(root: drive, iCloud: true)
            remover = RecordingRemover(trashFolder: fx.root.appending(path: "Trash"))
            settings = fx.fileSettings
        }

        var store: OffloadStore { OffloadStore(directory: fx.root.appending(path: "offloads")) }

        var engine: OffloadEngine {
            OffloadEngine(destination: drive, probe: probe, cloud: cloud, context: fx.context(settings: settings),
                          rules: [FixtureRules.archives] + FilesRules.all, git: FakeRunner(), store: store,
                          remover: remover, history: fx.historyLog)
        }

        func staleProject(_ name: String = "rusty") throws -> OffloadCandidate {
            let p = try fx.dir("WebstormProjects/\(name)")
            try fx.file("Cargo.toml", bytes: 40, in: p)
            try fx.file("src/main.rs", bytes: 300_000, in: p)
            try fx.file(".git/HEAD", bytes: 23, in: p)
            let longAgo = Date(timeIntervalSinceNow: -86400 * 200)
            try FixtureWorld.setModificationDates(in: p, to: longAgo)
            OffloadEngine.setTimes(p.path, longAgo)
            return OffloadCandidate(kind: .project, path: p, displayName: name, size: 300_000)
        }

        func offloaded(_ name: String = "rusty") async throws -> OffloadRecord {
            let report = await engine.offload([try staleProject(name)], execute: true)
            let r = try #require(report.results.first)
            #expect(r.status == .offloaded(trashed: true), "\(r.status)")
            return try #require(r.record)
        }
    }

    @Test func aFolderInICloudDriveIsAnAcceptedDestination() async throws {
        let w = try World()
        let check = w.engine.checkDestination()
        #expect(check.isReady, "\(check)")
        #expect(check.status?.isICloud == true)
        #expect(check.status?.isNetwork == false)
        #expect(check.message.contains("iCloud Drive"))
        let record = try await w.offloaded()
        #expect(record.manifest.archivePath.hasPrefix(w.drive.appending(path: "projects/rusty").path + "/"))
        #expect(FileManager.default.fileExists(atPath: record.manifest.payloadPath))
        #expect(OffloadLayout.partials(in: w.drive).isEmpty)
    }

    @Test func aPlainLocalFolderIsStillRefused() throws {
        let w = try World()
        let elsewhere = try w.fx.dir("NotICloud", in: w.fx.root)
        let check = DestinationCheck.check(elsewhere, probe: w.probe)
        if case .notNetwork = check {} else { Issue.record("a local folder outside iCloud Drive must be refused: \(check)") }
        // The real probe: a temp folder is neither a share nor in ~/Library/Mobile Documents.
        let real = DestinationCheck.check(elsewhere, probe: LiveVolumeProbe())
        if case .notNetwork = real {} else { Issue.record("expected notNetwork from the real probe: \(real)") }
    }

    @Test func iCloudDrivePathDetection() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(ICloudDrive.contains(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Archive"), home: home))
        #expect(ICloudDrive.contains(ICloudDrive.root(home: home), home: home))
        #expect(!ICloudDrive.contains(ICloudDrive.container(home: home), home: home))
        #expect(!ICloudDrive.contains(home.appending(path: "Library/Mobile Documents-evil/x"), home: home))
        #expect(!ICloudDrive.contains(home.appending(path: "Documents"), home: home))
        #expect(!ICloudDrive.contains(home.appending(path: "Library/Mobile Documents/../Caches/x"), home: home))
    }

    @Test func nothingIsEvictedBeforeMacOSSaysItIsUploaded() async throws {
        let w = try World()
        let record = try await w.offloaded()
        let report = w.engine.evictLocalCopies(execute: true)
        #expect(report.results.map(\.status) == [.notUploaded])
        #expect(report.waitingForUpload == 1)
        #expect(report.evictedCount == 0)
        #expect(w.cloud.evicted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: record.manifest.payloadPath))
    }

    @Test func evictionIsADryRunByDefault() async throws {
        let w = try World()
        _ = try await w.offloaded()
        w.cloud.uploaded = true
        let report = w.engine.evictLocalCopies()
        #expect(report.dryRun)
        #expect(report.results.map(\.status) == [.wouldEvict])
        #expect(report.evictableBytes > 0)
        #expect(w.cloud.evicted.isEmpty)
        #expect(!w.fx.historyLog.entries().contains { $0.ruleIDs == ["offload:evict"] })
    }

    @Test func uploadedPayloadsAreEvictedAndTheManifestStays() async throws {
        let w = try World()
        let record = try await w.offloaded()
        w.cloud.uploaded = true
        let report = w.engine.evictLocalCopies(execute: true)
        #expect(report.results.map(\.status) == [.evicted])
        #expect(w.cloud.evicted == [record.manifest.payloadPath])
        #expect(!w.cloud.evicted.contains(record.manifest.manifestPath))
        let entry = try #require(w.fx.historyLog.entries().last)
        #expect(entry.ruleIDs == ["offload:evict"])
        #expect(entry.items.first?.succeeded == true)
        // A second pass has nothing left to do.
        #expect(w.engine.evictLocalCopies(execute: true).results.map(\.status) == [.alreadyEvicted])
    }

    @Test func onlyUploadedArchivesGoWhenSomeAreStillUploading() async throws {
        let w = try World()
        let done = try await w.offloaded("done")
        let pending = try await w.offloaded("pending")
        w.cloud.markUploaded(URL(filePath: done.manifest.payloadPath))
        let report = w.engine.evictLocalCopies(execute: true)
        let byID = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0.status) })
        #expect(byID[done.id] == .evicted)
        #expect(byID[pending.id] == .notUploaded)
        #expect(w.cloud.evicted == [done.manifest.payloadPath])
    }

    @Test func aFailedEvictionIsReportedAndRecorded() async throws {
        let w = try World()
        _ = try await w.offloaded()
        w.cloud.uploaded = true
        w.cloud.evictError = "iCloud said no"
        let report = w.engine.evictLocalCopies(execute: true)
        #expect(report.results.first?.status == .failed("iCloud said no"))
        #expect(report.evictedCount == 0)
        #expect(w.fx.historyLog.entries().last?.items.first?.succeeded == false)
    }

    @Test func archivesOnANASAreNeverEvicted() async throws {
        let w = try World()
        let nas = try w.fx.dir("NAS", in: w.fx.root)
        let nasProbe = FakeVolumeProbe(root: nas)
        let cloud = FakeCloudStorage(uploaded: true)
        let engine = OffloadEngine(destination: nas, probe: nasProbe, cloud: cloud, context: w.fx.context(settings: w.settings),
                                   rules: [FixtureRules.archives] + FilesRules.all, git: FakeRunner(), store: w.store,
                                   remover: w.remover, history: w.fx.historyLog)
        let report = await engine.offload([try w.staleProject()], execute: true)
        #expect(report.results.first?.status == .offloaded(trashed: true))
        #expect(engine.evictLocalCopies(execute: true).results.map(\.status) == [.notInICloud])
        #expect(cloud.evicted.isEmpty)
    }

    @Test func restoreStillWorksAfterEviction() async throws {
        let w = try World()
        let record = try await w.offloaded()
        w.cloud.uploaded = true
        #expect(w.engine.evictLocalCopies(execute: true).evictedCount == 1)
        let target = try w.fx.dir("Restored", in: w.fx.home)
        let result = await w.engine.restore(record, into: target, execute: true)
        #expect(result.succeeded, "\(String(describing: result.error))")
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "rusty/src/main.rs").path))
    }
}
