import Foundation
import Testing
@testable import MajorTomCLI
@testable import MajorTomCore

/// A throwaway fake home in the temp directory; only ever removes itself.
private final class CLIFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "MajorTomTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        if root.path.contains("MajorTomTests-") { try? FileManager.default.removeItem(at: root) }
    }

    /// A user file last modified and added `daysAgo` days ago.
    @discardableResult
    func oldFile(_ rel: String, daysAgo: Double = 2000) throws -> URL {
        let url = home.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 200_000).write(to: url)
        let date = Date(timeIntervalSinceNow: -daysAgo * 86400)
        try FileTimes.set(url, modified: date, added: date)
        return url
    }

    var context: RuleContext {
        var s = Settings()
        s.oldFileMinimumMB = 0
        s.oldFileDays = 365
        s.projectRoots = []
        return RuleContext(home: home, allowedSystemRoots: [], runner: NoRunner(), environment: [:], settings: s)
    }
}

private struct NoRunner: CommandRunner {
    func run(_ argv: [String], timeout: TimeInterval) async -> CommandResult? { nil }
}

private func item(_ id: String, name: String? = nil, protected: Bool = false, flagged: Bool = false,
                  reportOnly: Bool = false) -> Item {
    Item(id: id, displayName: name ?? id, path: URL(filePath: "/tmp/\(id)"),
         methodOverride: reportOnly ? .reportOnly : nil, isProtected: protected, isFlagged: flagged)
}

private func selectionError(_ items: [Item], _ filters: [String], flagged: Bool = false) -> String? {
    do {
        _ = try CleanSelection.select(from: items, ruleID: "r", itemFilters: filters, flaggedOnly: flagged)
        return nil
    } catch { return error.message }
}

@Suite("CLI: clean selection")
struct CleanSelectionTests {
    let items = [item("a"), item("b", flagged: true), item("c", protected: true), item("d", reportOnly: true),
                 item("e", name: "same"), item("f", name: "same")]

    @Test func noFiltersSelectsEveryCleanableItem() throws {
        let ids = try CleanSelection.select(from: items, ruleID: "r", itemFilters: [], flaggedOnly: false).map(\.id)
        #expect(ids == ["a", "b", "e", "f"])
    }

    @Test func itemFilterSelectsExactlyThoseItems() throws {
        let ids = try CleanSelection.select(from: items, ruleID: "r", itemFilters: ["b", "a", "b"], flaggedOnly: false)
            .map(\.id)
        #expect(ids == ["b", "a"])
    }

    @Test func itemThatMatchesNothingFailsInsteadOfWidening() {
        #expect(selectionError(items, ["nope"])?.contains("no item nope in r") == true)
        #expect(selectionError(items, ["a", "nope"])?.contains("no item nope") == true)
    }

    @Test func ambiguousDisplayNameFails() throws {
        #expect(selectionError(items, ["same"])?.contains("matches 2 items") == true)
        #expect(try CleanSelection.select(from: items, ruleID: "r", itemFilters: ["e"], flaggedOnly: false).map(\.id) == ["e"])
    }

    @Test func protectedOrReportOnlyItemsFail() {
        #expect(selectionError(items, ["c"])?.contains("protected") == true)
        #expect(selectionError(items, ["d"])?.contains("report-only") == true)
    }

    @Test func flaggedStillAppliesWithItemFilters() throws {
        // Previously --item replaced the selection and silently dropped --flagged.
        #expect(selectionError(items, ["a"], flagged: true)?.contains("not flagged") == true)
        #expect(try CleanSelection.select(from: items, ruleID: "r", itemFilters: ["b"], flaggedOnly: true).map(\.id) == ["b"])
        #expect(try CleanSelection.select(from: items, ruleID: "r", itemFilters: [], flaggedOnly: true).map(\.id) == ["b"])
    }

    @Test func flaggedWithNothingFlaggedFails() {
        #expect(selectionError([item("a")], [], flagged: true)?.contains("no flagged") == true)
    }

    /// The exact command from issue #2, end to end against a fixture home: it must resolve to the one named file,
    /// and a real clean (fixture Trash folder only) must touch nothing else.
    @Test func issue2CommandCleansExactlyOneItem() async throws {
        let f = try CLIFixture()
        let target = try f.oldFile("Documents/Taxes 2019.pdf")
        let other1 = try f.oldFile("Documents/Old Report.pdf")
        let other2 = try f.oldFile("Desktop/notes-2018.txt")

        guard case .run(let inv) = try CLI.parse(
            ["majortom", "clean", "--rule", "old-files", "--item=\(target.path)", "--execute"]) else {
            Issue.record("expected a runnable clean"); return
        }
        #expect(inv.has("--execute"))

        let rule = try #require(RuleCatalogue.all.first { $0.id == inv.value("--rule") })
        let found = await rule.resolveItems(f.context).items
        #expect(found.count == 3)
        let selected = try CleanSelection.select(from: found, ruleID: rule.id, itemFilters: inv.all("--item"),
                                                 flaggedOnly: inv.has("--flagged"))
        #expect(selected.count == 1)
        #expect(selected.first?.path?.standardizedFileURL == target.standardizedFileURL)

        let trash = f.root.appending(path: "Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let engine = CleanEngine(context: f.context, history: HistoryLog(url: f.root.appending(path: "history.jsonl")),
                                 freeSpace: { 0 }, git: NoRunner(), remover: FolderTrashRemover(trashFolder: trash))
        let report = await engine.clean([CleanRequest(ruleID: rule.id, itemIDs: selected.map(\.id))],
                                        execute: inv.has("--execute"))
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes.first?.status == .cleaned)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: other1.path))
        #expect(FileManager.default.fileExists(atPath: other2.path))
    }

    @Test func issue2CommandWithAMissingItemCleansNothing() async throws {
        let f = try CLIFixture()
        try f.oldFile("Documents/Taxes 2019.pdf")
        let rule = try #require(RuleCatalogue.all.first { $0.id == "old-files" })
        let found = await rule.resolveItems(f.context).items
        #expect(found.count == 1)
        #expect(selectionError(found, [f.home.appending(path: "Documents/missing.pdf").path])?.contains("no item") == true)
    }
}
