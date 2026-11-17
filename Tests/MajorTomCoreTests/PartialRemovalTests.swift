import Darwin
import Foundation
import Testing
@testable import MajorTomCore

/// Stops a background writer thread.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}

/// `depth` nested folders `d/d/d/…` under `root` with a file at the bottom (fd-relative: deeper than PATH_MAX).
private func nest(_ root: URL, depth: Int) throws {
    var fd = open(root.path, O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else { throw POSIXError(.ENOENT) }
    for _ in 0..<depth {
        mkdirat(fd, "d", 0o755)
        let next = openat(fd, "d", O_RDONLY | O_DIRECTORY)
        close(fd)
        guard next >= 0 else { throw POSIXError(.EMFILE) }
        fd = next
    }
    close(openat(fd, "f", O_CREAT | O_WRONLY, 0o600))
    close(fd)
}

private func setFlags(_ url: URL, _ flags: Int32) {
    _ = chflags(url.path(percentEncoded: false), UInt32(flags))
}

@Suite("Partial removal")
struct PartialRemovalTests {
    func engine(_ f: Fixture, rules: [Rule]) -> CleanEngine {
        CleanEngine(rules: rules, context: f.context(), history: f.historyLog, freeSpace: { 1_000 },
                    remover: RecordingRemover(trashFolder: f.root.appending(path: "Trash")))
    }

    @Test func removesAWholeTree() throws {
        let f = try Fixture()
        let item = try f.dir("cache/item")
        try f.file("cache/item/a")
        try f.file("cache/item/sub/b")
        try f.file("cache/item/sub/deeper/c")
        let r = TreeRemover.remove(item)
        #expect(r.isComplete && r.rootRemoved)
        #expect(r.removedEntries == 6)  // 3 files, 3 folders
        #expect(r.removedBytes > 0)
        #expect(!f.exists(item))
    }

    @Test func keepingFolderEmptiesItAndLeavesIt() throws {
        let f = try Fixture()
        let item = try f.dir("cache/item")
        try f.file("cache/item/a")
        try f.file("cache/item/sub/b")
        let r = TreeRemover.remove(item, keepingFolder: true)
        #expect(r.isComplete && !r.rootRemoved)
        #expect(FS.isDirectory(item))
        #expect(FS.children(of: item).isEmpty)
    }

    @Test func neverFollowsSymlinks() throws {
        let f = try Fixture()
        let outside = try f.file("outside/keep.txt", in: f.root)
        let item = try f.dir("cache/item")
        try f.file("cache/item/a")
        try f.symlink("cache/item/link", to: outside.deletingLastPathComponent())
        try f.symlink("cache/item/filelink", to: outside)
        let r = TreeRemover.remove(item)
        #expect(r.isComplete)
        #expect(!f.exists(item))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func aSymlinkItemIsRemovedAsALinkEvenWhenKeepingFolders() throws {
        let f = try Fixture()
        let outside = try f.file("outside/keep.txt", in: f.root)
        try f.symlink("cache/link", to: outside.deletingLastPathComponent())
        let link = f.home.appending(path: "cache/link")
        let r = TreeRemover.remove(link, keepingFolder: true)
        #expect(r.isComplete && r.rootRemoved)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func lockedChildIsLeftBehindTheRestIsRemovedAndTheResultIsPartial() async throws {
        let f = try Fixture()
        try f.file("cache/item/a", bytes: 64 * 1024)
        try f.file("cache/item/sub/b")
        let locked = try f.file("cache/item/sub/locked.log")
        setFlags(locked, UF_IMMUTABLE)
        defer { setFlags(locked, 0) }
        let item = f.home.appending(path: "cache/item")

        let report = await engine(f, rules: [testRule()])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [item.path])], sizes: [item.path: 100_000], execute: true)
        let o = try #require(report.outcomes.first)
        guard case .partial(let text) = o.status else { Issue.record("expected partial, got \(o.status)"); return }
        #expect(text.contains("removed 2 entries"))
        #expect(text.contains("chflags -R nouchg"))
        #expect(o.leftBehindCount == 1)
        #expect(o.leftBehind.first?.path == locked.path)
        #expect(o.leftBehind.first?.errno == EPERM)
        #expect(o.underlyingError?.contains("errno 1") == true)
        #expect(f.exists(locked))
        #expect(!f.exists(item.appending(path: "a")) && !f.exists(item.appending(path: "sub/b")))
        // Partial results count what was removed, not the whole estimate.
        // …and never more than the delete actually removed.
        let removed = try #require(o.removedBytes)
        #expect(report.estimatedBytes == min(100_000 - o.leftBehindBytes, removed))

        let record = try #require(f.historyLog.entries().last?.items.first)
        #expect(record.succeeded == false)
        #expect(record.partial == true)
        #expect(record.error?.contains("chflags") == true)
        #expect(record.leftBehind?.first?.path == locked.path)
        #expect(record.underlyingError?.contains("unlink") == true)
    }

    @Test func readOnlyFolderSaysHowToFixIt() async throws {
        let f = try Fixture()
        try f.file("cache/item/a")
        let ro = try f.dir("cache/item/ro")
        try f.file("cache/item/ro/f")
        chmod(ro.path, 0o555)
        defer { chmod(ro.path, 0o755) }
        let item = f.home.appending(path: "cache/item")

        let report = await engine(f, rules: [testRule()])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [item.path])], execute: true)
        let o = try #require(report.outcomes.first)
        guard case .partial(let text) = o.status else { Issue.record("expected partial, got \(o.status)"); return }
        #expect(text.contains("read-only") && text.contains("chmod u+w"))
        #expect(o.leftBehind.map(\.path) == [ro.path + "/f"])  // the folder holding it isn't listed again
        #expect(o.leftBehind.first?.errno == EACCES)
    }

    @Test func nothingRemovableIsAFailureWithAdvice() async throws {
        let f = try Fixture()
        let locked = try f.file("cache/locked.log")
        setFlags(locked, UF_IMMUTABLE)
        defer { setFlags(locked, 0) }
        let report = await engine(f, rules: [testRule()])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [locked.path])], execute: true)
        let o = try #require(report.outcomes.first)
        guard case .failed(let text) = o.status else { Issue.record("expected failed, got \(o.status)"); return }
        #expect(text.contains("locked") && text.contains("nouchg"))
        #expect(!text.contains("don’t have permission"))
        #expect(report.estimatedBytes == 0)
    }

    /// The real-world failure: a booted simulator recreated its log folder while it was being deleted, so the
    /// final rmdir failed with ENOTEMPTY — which `FileManager.removeItem` reports as "you don't have permission".
    @Test func folderRefilledDuringRemovalIsRetriedAndNeverReportedAsAPermissionProblem() throws {
        let f = try Fixture()
        let item = try f.dir("cache/CoreSimulator")
        for i in 0..<300 { try f.file("cache/CoreSimulator/DEVICE/f\(i)", bytes: 16) }
        let refilled = item.appending(path: "DEVICE/com.apple.itunesstored")
        try f.file("cache/CoreSimulator/DEVICE/com.apple.itunesstored/itunesstored.log", bytes: 0)
        let stop = StopFlag()
        let dirPath = refilled.path, logPath = refilled.appending(path: "itunesstored.log").path
        let writer = Thread {
            while !stop.isStopped {
                mkdir(dirPath, 0o755)
                close(open(logPath, O_CREAT | O_WRONLY, 0o600))
            }
        }
        writer.start()
        let r = TreeRemover.remove(item)
        stop.stop()
        Thread.sleep(forTimeInterval: 0.05)
        for left in r.leftBehind {
            #expect(left.errno == ENOTEMPTY)
            #expect(left.advice.contains("refilled"))
            #expect(!left.advice.contains("Full Disk Access"))
        }
        #expect(r.removedEntries >= 300)
        try? FileManager.default.removeItem(at: item)
    }

    @Test func adviceForAnInUseSimulatorFolder() {
        let path = "/Users/x/Library/Logs/CoreSimulator/11111111-2222-3333-4444-555555555555"
        let advice = RemovalAdvice.advice(path: path, errno: ENOTEMPTY)
        #expect(advice.contains("Simulator") && advice.contains("quit"))
        #expect(RemovalAdvice.advice(path: path, errno: EBUSY).contains("Simulator"))
    }

    @Test func foundationErrorsAreTranslatedFromTheirPOSIXCause() throws {
        let f = try Fixture()
        let locked = try f.file("cache/locked")
        setFlags(locked, UF_IMMUTABLE)
        defer { setFlags(locked, 0) }
        do {
            try FileManager.default.removeItem(at: locked)
            Issue.record("expected an error")
        } catch {
            let (advice, underlying) = RemovalAdvice.advice(for: error, path: locked.path)
            #expect(advice.contains("nouchg"))
            #expect(underlying.contains("513") && underlying.contains("errno 1"))
        }
    }

    @Test func logsRuleEmptiesEachAppFolderButKeepsIt() async throws {
        let f = try Fixture()
        let sim = try f.dir("Library/Logs/CoreSimulator")
        try f.file("Library/Logs/CoreSimulator/DEVICE/system.log")
        try f.file("Library/Logs/CoreSimulator/DEVICE/asl/2025.asl")
        let loose = try f.file("Library/Logs/old.log")
        let outside = try f.file("elsewhere/keep.log", in: f.root)
        try f.symlink("Library/Logs/linked", to: outside.deletingLastPathComponent())
        #expect(SystemRules.logs.method == .deleteContents)
        #expect(SystemRules.genericCaches.method == .deleteContents)

        let ids = [sim.path, loose.path, f.home.appending(path: "Library/Logs/linked").path]
        let report = await engine(f, rules: [SystemRules.logs])
            .clean([CleanRequest(ruleID: "logs", itemIDs: ids)], execute: true)
        #expect(report.outcomes.map(\.status) == [.cleaned, .cleaned, .cleaned])
        #expect(FS.isDirectory(sim))
        #expect(FS.children(of: sim).isEmpty)
        #expect(!f.exists(loose))
        #expect(!f.exists(f.home.appending(path: "Library/Logs/linked")))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(f.historyLog.entries().last?.items.allSatisfy { $0.succeeded && $0.partial == nil } == true)
    }

    @Test func trashOnlyRulesStillRefuseDeletingContents() async throws {
        let f = try Fixture()
        let item = try f.file("cache/thing")
        var rule = testRule(method: .deleteContents)
        rule.trashOnly = true
        let report = await engine(f, rules: [rule])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [item.path])], execute: true)
        guard case .skipped(let why)? = report.outcomes.first?.status else { Issue.record("expected skipped"); return }
        #expect(why.contains("only ever moves items to the Trash"))
        #expect(f.exists(item))
    }

    /// Recursion used ~4 KB of stack per level: a few hundred nested folders crashed the process (SIGBUS) on a
    /// 512 KB cooperative-pool thread, mid-delete.
    @Test func deepTreeOnAPoolThreadDoesNotCrash() async throws {
        let f = try Fixture()
        let item = try f.dir("cache/deep")
        try nest(item, depth: 600)
        let r = await Task.detached { TreeRemover.remove(item) }.value
        #expect(r.isComplete || r.leftBehind.allSatisfy { $0.errno == EMFILE })
    }

    @Test func treesDeeperThanTheLimitAreLeftBehindNotFollowedForever() async throws {
        let f = try Fixture()
        let item = try f.dir("cache/deep")
        try nest(item, depth: TreeRemover.maxDepth + 5)
        let r = await Task.detached { TreeRemover.remove(item) }.value
        #expect(!r.isComplete && !r.rootRemoved)
        #expect(r.leftBehind.contains { $0.advice.contains("nested too deeply") }
                || r.leftBehind.allSatisfy { $0.errno == EMFILE })
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/bin/rm")
        rm.arguments = ["-rf", item.path]
        try rm.run()
        rm.waitUntilExit()
    }

    /// The engine validates first, but the remover is public: a root ending in `..` emptied the grandparent.
    @Test func refusesRootsWithDotComponentsOrRelativePaths() throws {
        let f = try Fixture()
        let keep = try f.file("cache/keep.txt")
        try f.dir("cache/a")
        let r = TreeRemover.remove(URL(fileURLWithPath: f.home.appending(path: "cache/a").path + "/.."))
        #expect(!r.isComplete && r.removedEntries == 0)
        #expect(f.exists(keep))
        let r2 = TreeRemover.remove(URL(fileURLWithPath: f.home.appending(path: "cache").path + "/./a"))
        #expect(r2.removedEntries == 0 && f.exists(f.home.appending(path: "cache/a")))
        #expect(TreeRemover.remove(URL(fileURLWithPath: "/")).removedEntries == 0)
    }

    /// A folder that can't be opened counts 0 left-behind bytes, so "estimate minus left behind" claimed the
    /// whole scan size for a partial delete that freed almost nothing.
    @Test func partialEstimateNeverExceedsWhatWasActuallyRemoved() async throws {
        let f = try Fixture()
        try f.file("cache/item/small", bytes: 4096)
        let sealed = try f.dir("cache/item/sealed")
        try f.file("cache/item/sealed/big", bytes: 2_000_000)
        chmod(sealed.path, 0o000)
        defer { chmod(sealed.path, 0o755) }
        let item = f.home.appending(path: "cache/item")
        let report = await engine(f, rules: [testRule()])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [item.path])], sizes: [item.path: 2_010_000], execute: true)
        let o = try #require(report.outcomes.first)
        guard case .partial = o.status else { Issue.record("expected partial, got \(o.status)"); return }
        #expect(report.estimatedBytes <= 64 * 1024)
        #expect(f.historyLog.entries().last?.estimatedBytes == report.estimatedBytes)
    }

    @Test func dryRunTouchesNothing() async throws {
        let f = try Fixture()
        let item = try f.file("cache/item/a")
        let report = await engine(f, rules: [testRule(method: .deleteContents)])
            .clean([CleanRequest(ruleID: "test-cache", itemIDs: [item.deletingLastPathComponent().path])])
        #expect(report.outcomes.map(\.status) == [.wouldClean])
        #expect(f.exists(item))
    }
}
