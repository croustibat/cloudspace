import Foundation
import Testing
@testable import MajorTomCore

/// Records every delete/trash. "Trash" moves into a folder inside the fixture, never the user's real Trash.
final class RecordingRemover: FileRemover, @unchecked Sendable {
    private let lock = NSLock()
    private let folder: FolderTrashRemover
    private var _deleted: [URL] = []
    private var _trashed: [URL] = []

    init(trashFolder: URL) { folder = FolderTrashRemover(trashFolder: trashFolder) }

    func delete(_ url: URL, keepingFolder: Bool) -> TreeRemoval {
        lock.withLock { _deleted.append(url) }
        return TreeRemover.remove(url, keepingFolder: keepingFolder)
    }

    func trash(_ url: URL) throws {
        lock.withLock { _trashed.append(url) }
        try folder.trash(url)
    }

    var deleted: [URL] { lock.withLock { _deleted } }
    var trashed: [URL] { lock.withLock { _trashed } }
}

private let day: TimeInterval = 86400

extension Fixture {
    /// A file with given size and dates (modification and "date added"), `days` ago.
    @discardableResult
    func userFile(_ rel: String, mb: Double, daysAgo days: Double = 0) throws -> URL {
        let url = try file(rel, bytes: Int(mb * 1_000_000))
        let date = Date(timeIntervalSinceNow: -days * day)
        try FileTimes.set(url, modified: date, added: date)
        return url
    }

    func backdate(_ rel: String, days: Double) throws {
        try FixtureWorld.backdate(home.appending(path: rel), to: Date(timeIntervalSinceNow: -days * day))
    }

    var fileSettings: Settings {
        var s = Settings()
        s.largeFileThresholdMB = 1
        s.oldFileMinimumMB = 0
        s.oldFileDays = 365
        s.projectRoots = ["~/WebstormProjects"]
        return s
    }

    func resolve(_ rule: Rule, _ ctx: RuleContext) async -> (items: [Item], error: String?, denied: [String]) {
        await rule.resolveItems(ctx)
    }
}

@Suite("General cleanup: files")
struct FilesRuleTests {
    @Test func largeFilesSkipProjectsReposPackagesAndLibraries() async throws {
        let f = try Fixture()
        let plain = try f.userFile("Documents/Exports/render.mov", mb: 2)
        try f.userFile("Documents/Code/heliosphere/assets/big.bin", mb: 2)
        try f.dir("Documents/Code/heliosphere/.git")
        try f.userFile("Documents/site/public/hero.mp4", mb: 2)
        try f.text("Documents/site/package.json", "{}")
        try f.userFile("Documents/App/App.xcodeproj/project.pbxproj", mb: 0.01)
        try f.userFile("Documents/App/Resources/huge.bin", mb: 2)
        try f.userFile("Movies/Photos Library.photoslibrary/originals/IMG.heic", mb: 2)
        try f.userFile("Movies/TV/Media/Movies/Film.m4v", mb: 2)
        try f.userFile("Downloads/Tool.app/Contents/MacOS/Tool", mb: 2)
        try f.userFile("Downloads/.hidden/secret.bin", mb: 2)
        try f.userFile("Desktop/node_modules/x/blob", mb: 2)
        try f.userFile("WebstormProjects/raw.bin", mb: 2)
        let outside = try f.userFile("elsewhere/linked.bin", mb: 2)
        try f.symlink("Desktop/linked.bin", to: outside)
        try f.userFile("Desktop/small.txt", mb: 0.2)

        let ctx = f.context(settings: f.fileSettings)
        let r = await f.resolve(FilesRules.largeFiles, ctx)
        #expect(r.error == nil)
        let paths = Set(r.items.compactMap(\.path?.path))
        #expect(paths == [plain.path, f.home.appending(path: "Downloads/Tool.app").path])
        let app = try #require(r.items.first { $0.displayName == "Tool.app" })
        #expect(app.note?.contains("app bundle") == true)
        #expect((app.size ?? 0) >= 2_000_000)
        #expect(r.items.allSatisfy { $0.methodOverride == .trash })
    }

    @Test func eachFileLandsInExactlyOneRule() async throws {
        let f = try Fixture()
        let xip = try f.userFile("Downloads/Xcode.xip", mb: 3, daysAgo: 500)
        let zip = try f.userFile("Downloads/fonts.zip", mb: 0.1, daysAgo: 2)
        let movie = try f.userFile("Downloads/tour.mov", mb: 3, daysAgo: 500)
        let pdf = try f.userFile("Documents/Taxes 2019.pdf", mb: 0.5, daysAgo: 2000)
        let fresh = try f.userFile("Documents/fresh.pdf", mb: 0.5, daysAgo: 3)
        let docDmg = try f.userFile("Documents/backup.dmg", mb: 3, daysAgo: 10)

        let ctx = f.context(settings: f.fileSettings)
        let installers = Set(await f.resolve(FilesRules.installers, ctx).items.compactMap(\.path?.path))
        let large = Set(await f.resolve(FilesRules.largeFiles, ctx).items.compactMap(\.path?.path))
        let old = Set(await f.resolve(FilesRules.oldFiles, ctx).items.compactMap(\.path?.path))
        #expect(installers == [xip.path, zip.path])
        #expect(large == [movie.path, docDmg.path])  // a .dmg outside Downloads is just a large file
        #expect(old == [pdf.path])
        #expect(!old.contains(fresh.path))
        #expect(installers.isDisjoint(with: large) && large.isDisjoint(with: old) && installers.isDisjoint(with: old))

        let largeItems = await f.resolve(FilesRules.largeFiles, ctx).items
        #expect(largeItems.first { $0.path == movie }?.isFlagged == true)   // large and untouched for a year
        #expect(largeItems.first { $0.path == docDmg }?.isFlagged == false)
    }

    @Test func oldMeansNothingRecentInModifiedOrAdded() async throws {
        let f = try Fixture()
        let url = try f.file("Documents/unzipped/old-looking.psd", bytes: 500_000)
        // Modified long ago (e.g. preserved by unzip) but only just added to the folder: not old.
        try FileTimes.set(url, modified: Date(timeIntervalSinceNow: -900 * day), added: Date())
        let ctx = f.context(settings: f.fileSettings)
        #expect(await f.resolve(FilesRules.oldFiles, ctx).items.isEmpty)
        try FileTimes.set(url, modified: Date(timeIntervalSinceNow: -900 * day), added: Date(timeIntervalSinceNow: -800 * day))
        #expect(await f.resolve(FilesRules.oldFiles, ctx).items.map(\.path) == [url])
    }

    @Test func mediaNextToAnEditorProjectIsWarnedAndRenderCachesAreSkipped() async throws {
        let f = try Fixture()
        try f.userFile("Movies/Promo/Promo.prproj", mb: 0.1, daysAgo: 500)
        let footage = try f.userFile("Movies/Promo/footage/A001.mp4", mb: 2, daysAgo: 500)
        try f.userFile("Movies/Promo/Adobe Premiere Pro Audio Previews/Promo.PRV/x.cfa", mb: 2, daysAgo: 500)
        let r = await f.resolve(FilesRules.largeFiles, f.context(settings: f.fileSettings))
        #expect(r.items.map(\.path) == [footage])
        #expect(r.items[0].note?.contains("Premiere Pro project") == true)
        #expect(r.items[0].isFlagged == false)
    }

    @Test func mountedInstallerIsProtected() async throws {
        let f = try Fixture()
        let dmg = try f.userFile("Downloads/Starman.dmg", mb: 0.2)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>images</key><array><dict>
        <key>image-path</key><string>\(dmg.path)</string></dict></array></dict></plist>
        """
        let ctx = f.context(runner: FakeRunner(["hdiutil info -plist": plist]), settings: f.fileSettings)
        let item = try #require(await f.resolve(FilesRules.installers, ctx).items.first)
        #expect(item.isProtected)
        #expect(item.note?.contains("mounted") == true)
    }

    @Test func deniedFolderIsReportedNotSilentlyEmpty() async throws {
        let f = try Fixture()
        let dl = try f.userFile("Downloads/movie.mov", mb: 2)
        try f.userFile("Documents/secret.mov", mb: 2)
        let docs = f.home.appending(path: "Documents")
        #expect(chmod(docs.path, 0) == 0)
        defer { chmod(docs.path, 0o755) }

        let ctx = f.context(settings: f.fileSettings)
        let r = await f.resolve(FilesRules.largeFiles, ctx)
        #expect(r.items.map(\.path) == [dl])
        #expect(r.denied == ["~/Documents"])
        #expect(r.error?.contains("Files & Folders") == true)

        // Installers only look at Downloads, so a locked Documents folder isn't their problem.
        #expect(await f.resolve(FilesRules.installers, ctx).denied.isEmpty)

        let scanned = await Scanner(rules: [FilesRules.largeFiles], context: ctx).scanAll()
        #expect(scanned[0].deniedPaths == ["~/Documents"])
        #expect(scanned[0].items.count == 1)
    }
}

@Suite("General cleanup: Trash only")
struct TrashOnlyTests {
    func engine(_ f: Fixture, rules: [Rule], remover: RecordingRemover, settings: Settings? = nil) -> CleanEngine {
        CleanEngine(rules: rules, context: f.context(settings: settings ?? f.fileSettings), history: f.historyLog,
                    freeSpace: { 1_000 }, remover: remover)
    }

    @Test func m5RulesAreReviewTierTrashOnlyAndNeverSafe() {
        let m5 = RuleCatalogue.all.filter { ["large-files", "old-files", "installer-leftovers", "orphaned-app-data"].contains($0.id) }
        #expect(m5.count == 4)
        for rule in m5 {
            #expect(rule.tier == .review)
            #expect(rule.method == .trash)
            #expect(rule.isTrashOnly)
        }
    }

    @Test func executeMovesToTrashAndNeverDeletes() async throws {
        let f = try Fixture()
        let movie = try f.userFile("Movies/big.mov", mb: 2)
        let remover = RecordingRemover(trashFolder: f.root.appending(path: "Trash"))
        let report = await engine(f, rules: [FilesRules.largeFiles], remover: remover)
            .clean([CleanRequest(ruleID: "large-files", itemIDs: [movie.path])], execute: true)
        #expect(report.outcomes.map(\.status) == [.cleaned])
        #expect(remover.deleted.isEmpty)
        #expect(remover.trashed == [movie])
        #expect(!f.exists(movie))
        #expect(FileManager.default.fileExists(atPath: f.root.appending(path: "Trash/big.mov").path))
        #expect(f.historyLog.entries().count == 1)
    }

    @Test func aTrashOnlyRuleCannotBeTurnedIntoADelete() async throws {
        let f = try Fixture()
        let a = try f.userFile("Movies/a.mov", mb: 2)
        let b = try f.userFile("Movies/b.mov", mb: 2)
        // The rule's own method switched to delete (items without an override inherit it)…
        var tampered = FilesRules.largeFiles
        tampered.method = .delete
        tampered.resolve = { ctx in
            try await FilesRules.largeFiles.resolve(ctx).filter { $0.path == a }.map { var i = $0; i.methodOverride = nil; return i }
        }
        // …or an item claiming to be deleted.
        var overriding = FilesRules.largeFiles
        overriding.id = "overriding"
        overriding.resolve = { ctx in
            try await FilesRules.largeFiles.resolve(ctx).filter { $0.path == b }.map { var i = $0; i.methodOverride = .delete; return i }
        }
        let remover = RecordingRemover(trashFolder: f.root.appending(path: "Trash"))
        let report = await engine(f, rules: [tampered, overriding], remover: remover)
            .clean([CleanRequest(ruleID: "large-files", itemIDs: [a.path]),
                    CleanRequest(ruleID: "overriding", itemIDs: [b.path])], execute: true)
        #expect(report.outcomes.count == 2)
        for o in report.outcomes {
            guard case .skipped(let why) = o.status else { Issue.record("expected skip, got \(o.status)"); continue }
            #expect(why.contains("only ever moves items to the Trash"))
        }
        #expect(remover.deleted.isEmpty && remover.trashed.isEmpty)
        #expect(f.exists(a) && f.exists(b))
    }

    @Test func filesCategoryIsTrashOnlyEvenWithoutTheFlag() {
        var rule = testRule(method: .delete)
        rule.category = .files
        #expect(rule.isTrashOnly)
    }

    @Test func refusesUserFilesInsideProjectsPackagesAndLibraries() async throws {
        let f = try Fixture()
        let inRepo = try f.userFile("Documents/repo/assets/a.bin", mb: 0.1)
        try f.dir("Documents/repo/.git")
        let inProject = try f.userFile("Documents/site/b.bin", mb: 0.1)
        try f.text("Documents/site/Cargo.toml", "")
        let inApp = try f.userFile("Documents/Tool.app/Contents/c.bin", mb: 0.1)
        let library = try f.dir("Documents/Photos Library.photoslibrary")
        try f.userFile("Documents/Photos Library.photoslibrary/d.heic", mb: 0.1)
        let inRoot = try f.userFile("Documents/Code/e.bin", mb: 0.1)
        let fine = try f.userFile("Documents/fine.bin", mb: 0.1)
        let targets = [inRepo, inProject, inApp, library, inRoot, fine]
        // A rule whose resolver (wrongly) offers all of them: the engine must still refuse the bad ones.
        let rogue = Rule(id: "rogue", title: "Rogue", category: .files, tier: .review, impact: "", recovery: "",
                         regenCost: "", method: .trash,
                         baseDirectories: { [$0.path("Documents")] },
                         resolve: { _ in targets.map { Item(displayName: $0.lastPathComponent, path: $0) } })
        var settings = f.fileSettings
        settings.projectRoots = ["~/Documents/Code"]
        let remover = RecordingRemover(trashFolder: f.root.appending(path: "Trash"))
        let report = await engine(f, rules: [rogue], remover: remover, settings: settings)
            .clean([CleanRequest(ruleID: "rogue", itemIDs: targets.map(\.path))], execute: true)
        let status = Dictionary(uniqueKeysWithValues: report.outcomes.map { ($0.itemID, $0.status) })
        #expect(status[fine.path] == .cleaned)
        #expect(status[inRepo.path] == .skipped("refused: inside a project or git repository: \(inRepo.path)"))
        #expect(status[inProject.path] == .skipped("refused: inside a project or git repository: \(inProject.path)"))
        #expect(status[inApp.path] == .skipped("refused: inside an app bundle, library or other package: \(inApp.path)"))
        #expect(status[inRoot.path] == .skipped("refused: inside a project or git repository: \(inRoot.path)"))
        #expect(status[library.path] == .skipped("refused: a Photos/Music/TV-style library managed by an app: \(library.path)"))
        #expect(remover.trashed == [fine])
        #expect(remover.deleted.isEmpty)
    }

    @Test func dryRunIsStillTheDefault() async throws {
        let f = try Fixture()
        let movie = try f.userFile("Movies/big.mov", mb: 2)
        let remover = RecordingRemover(trashFolder: f.root.appending(path: "Trash"))
        let report = await engine(f, rules: [FilesRules.largeFiles], remover: remover)
            .clean([CleanRequest(ruleID: "large-files", itemIDs: [movie.path])])
        #expect(report.dryRun)
        #expect(report.outcomes.map(\.status) == [.wouldClean])
        #expect(remover.trashed.isEmpty && f.exists(movie))
    }
}

@Suite("General cleanup: orphaned app data")
struct OrphanTests {
    /// An installed app with a nested helper, and Library data of installed, removed and unknowable apps.
    func world() throws -> Fixture {
        let f = try Fixture()
        try f.plist("Applications/Starman.app/Contents/Info.plist", ["CFBundleIdentifier": "com.ziggy.starman"])
        try f.plist("Applications/Starman.app/Contents/Library/LoginItems/Launcher.app/Contents/Info.plist",
                    ["CFBundleIdentifier": "net.spiders.starman-launcher"])
        try f.plist("Applications/Utilities/Tool.app/Contents/Info.plist", ["CFBundleIdentifier": "org.utility.tool"])
        let folders: [(String, Double)] = [
            ("Library/Application Support/com.ziggy.starman", 200),
            ("Library/Caches/com.ziggy.starman.ShipIt", 200),
            ("Library/Application Support/net.spiders.starman-launcher", 200),
            ("Library/Application Support/org.utility.tool", 200),
            ("Library/Application Support/com.ziggy.legacy", 200),
            ("Library/Application Support/com.mars.spiders", 200),
            ("Library/Caches/com.mars.spiders", 200),
            ("Library/HTTPStorages/com.mars.spiders", 200),
            ("Library/Containers/com.mars.spiders", 200),
            ("Library/Containers/com.lowfi.station", 300),
            ("Library/Application Support/com.apple.something", 400),
            ("Library/Caches/com.vercel.cli", 400),
            ("Library/Caches/org.swift.swiftpm", 400),
            ("Library/Application Support/io.sentry", 400),
            ("Library/Application Support/com.heroes.oneday", 2),
            ("Library/Application Support/com.quiet.prefs", 300),
            ("Library/Application Support/io.stellar.desktop", 300),
            ("Library/Application Support/Some App", 300),
            ("Library/Application Support/twoparts.only", 300),
        ]
        for (rel, _) in folders { try f.file(rel + "/data.bin", bytes: 10_000) }
        try f.dir("WebstormProjects/web/stellar")
        try f.text("Library/Preferences/com.quiet.prefs.plist", "<plist/>")  // touched today: app still in use
        for (rel, days) in folders { try f.backdate(rel, days: days) }
        return f
    }

    @Test func listsOnlyConfidentOrphansWithAReason() async throws {
        let f = try world()
        let ctx = f.context(settings: f.fileSettings)
        let r = await f.resolve(OrphanedAppData.rule, ctx)
        #expect(r.error == nil)
        #expect(r.items.map(\.id) == ["orphan:com.lowfi.station", "orphan:com.mars.spiders"])
        let mars = try #require(r.items.first { $0.id == "orphan:com.mars.spiders" })
        #expect(mars.path == f.home.appending(path: "Library/Application Support/com.mars.spiders"))
        #expect(Set(mars.companionPaths.map(\.path)) == Set(["Library/Caches/com.mars.spiders", "Library/Containers/com.mars.spiders",
                                                             "Library/HTTPStorages/com.mars.spiders"].map { f.home.appending(path: $0).path }))
        #expect(mars.note?.contains("Not installed: no app with ID com.mars.spiders") == true)
        #expect(mars.note?.contains("Untouched since") == true)
        #expect(mars.methodOverride == .trash)
    }

    @Test func containersNeedAccessAndSayWhy() async throws {
        let f = try world()
        var ctx = f.context(settings: f.fileSettings)
        ctx.appSources.containersReadable = { false }
        let r = await f.resolve(OrphanedAppData.rule, ctx)
        #expect(r.items.map(\.id) == ["orphan:com.mars.spiders"])
        #expect(r.items[0].companionPaths.allSatisfy { !$0.path.contains("/Containers/") })
        #expect(r.denied == ["~/Library/Containers"])
        #expect(r.error?.contains("Full Disk Access") == true)
    }

    @Test func genericCachesLeaveOrphanedCachesToTheOrphanRule() async throws {
        let f = try world()
        let ctx = f.context(settings: f.fileSettings)
        let caches = await f.resolve(SystemRules.genericCaches, ctx).items.map(\.displayName)
        #expect(!caches.contains("com.mars.spiders"))
        #expect(caches.contains("com.ziggy.starman.ShipIt"))
        #expect(caches.contains("com.vercel.cli"))
    }

    @Test func installedAppMatching() {
        let apps = InstalledApps(bundleIDs: ["com.foo.app", "com.electron.thing"])
        #expect(apps.covers("com.foo.app"))
        #expect(apps.covers("COM.FOO.APP.ShipIt"))
        #expect(!apps.covers("com.foo.application"))
        #expect(apps.sameVendor("com.foo.other") == "com.foo.app")
        #expect(apps.sameVendor("com.electron.other") == nil)   // shared prefix says nothing
    }

    @Test func orphanCleanTrashesEveryFolderOfTheApp() async throws {
        let f = try world()
        let remover = RecordingRemover(trashFolder: f.root.appending(path: "Trash"))
        let engine = CleanEngine(rules: [OrphanedAppData.rule], context: f.context(settings: f.fileSettings),
                                 history: f.historyLog, freeSpace: { 0 }, remover: remover)
        let report = await engine.clean([CleanRequest(ruleID: "orphaned-app-data", itemIDs: ["orphan:com.mars.spiders"])],
                                        execute: true)
        #expect(report.outcomes.map(\.status) == [.cleaned])
        #expect(remover.trashed.count == 4)
        #expect(remover.deleted.isEmpty)
        #expect(!f.exists(f.home.appending(path: "Library/Caches/com.mars.spiders")))
        #expect(f.exists(f.home.appending(path: "Library/Application Support/com.ziggy.starman")))
    }

    @Test func settingsDecodeFileThresholdsTolerantly() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"staleAfterDays": 30}"#.utf8))
        #expect(old.largeFileThresholdMB == 500 && old.oldFileDays == 365 && old.oldFileMinimumMB == 50)
        var s = Settings()
        s.largeFileThresholdMB = 250
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back.largeFileThresholdMB == 250)
        #expect(back.fileRulesDiffer(from: Settings()))
    }
}
