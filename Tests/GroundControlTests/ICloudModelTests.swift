import Foundation
import Testing
@testable import GroundControl
@testable import MajorTomCore

/// Automatic eviction through the model: the fixture's offload folder is reported as iCloud Drive, upload state
/// comes from `FakeCloudStorage`.
@MainActor
@Suite("Ground Control model: iCloud Drive")
struct ICloudModelTests {
    final class World {
        let world: FixtureWorld
        let cloud = FakeCloudStorage()
        init() throws { world = try FixtureWorld.create(scale: 0.1) }
        deinit { world.destroy() }
        var env: AppEnvironment {
            var e = AppEnvironment.fixture(world)
            e.fullDiskAccess = { .granted }
            e.offloadProbe = FakeVolumeProbe(root: world.nasFolder, iCloud: true)
            e.offloadCloud = cloud
            return e
        }
    }

    /// A model with one file offloaded to the fake iCloud Drive.
    func offloaded(_ w: World) async throws -> GroundControlModel {
        let m = GroundControlModel(environment: w.env)
        m.updateSettings { $0.largeFileThresholdMB = 1; $0.oldFileMinimumMB = 0 }
        await m.scanOffloadCandidates()
        #expect(m.destinationIsICloud)
        #expect(m.destinationName == "iCloud Drive")
        let movie = try #require(m.offloadCandidates.first { $0.path.lastPathComponent == "Ziggy Stardust tour.mov" })
        m.setOffloadChecked(true, movie)
        await m.reviewOffload()
        m.confirmOffload()
        await m.offloadTask?.value
        guard case .finished(let report)? = m.offloadSession?.phase else { throw OffloadError.io("offload didn't finish") }
        #expect(report.results.allSatisfy { $0.status == .offloaded(trashed: true) }, "\(report.results.map(\.status))")
        m.dismissOffload()
        return m
    }

    @Test func nothingIsFreedWhileStillUploading() async throws {
        let w = try World()
        let m = try await offloaded(w)
        await m.autoEvictTick()
        #expect(w.cloud.evicted.isEmpty)
        #expect(m.evictionPreview?.waitingForUpload == 1)
    }

    @Test func uploadedArchivesAreFreedAutomatically() async throws {
        let w = try World()
        let m = try await offloaded(w)
        w.cloud.uploaded = true
        await m.autoEvictTick()
        #expect(w.cloud.evicted.count == 1)
        #expect(m.evictionPreview?.waitingForUpload == 0)
        #expect(m.evictionPreview?.evictableBytes == 0)
        #expect(m.offloadMessage?.contains("automatically") == true)
        #expect(m.history.first?.ruleIDs == ["offload:evict"])
    }

    @Test func theSettingTurnsAutomaticFreeingOff() async throws {
        let w = try World()
        let m = try await offloaded(w)
        m.setAutoEvict(false)
        w.cloud.uploaded = true
        await m.autoEvictTick()
        #expect(w.cloud.evicted.isEmpty)
        // The manual button still works.
        await m.freeLocalCopies()
        #expect(w.cloud.evicted.count == 1)
    }
}
