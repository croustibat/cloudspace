import Foundation

/// A self-contained fake home folder in the temp directory with rules that only ever point into it.
/// Used by the app's fixture mode (`MAJORTOM_FIXTURE=1` or `--fixture`) to exercise the whole clean flow
/// without touching anything real: the context's home is the fixture home, so the path validator refuses
/// anything outside it, and commands go to `SimulatedRunner`, which never executes anything.
public struct FixtureWorld: Sendable {
    public static let directoryPrefix = "MajorTomFixture-"

    public let root: URL
    public let home: URL
    public let runner: SimulatedRunner
    /// `--fixture-empty`: a home with nothing in it and no NAS folder chosen — what a fresh Mac looks like.
    public let isEmpty: Bool

    public var rules: [Rule] { FixtureRules.all }
    public var context: RuleContext {
        RuleContext(home: home, allowedSystemRoots: [], runner: runner, environment: [:], settings: settings)
    }
    /// Fixture thresholds, scaled to the fixture's megabyte-sized files. Project roots are detected (the fixture
    /// home has `~/WebstormProjects`); the offload destination is the fake NAS unless the fixture is empty.
    public var settings: Settings {
        var s = Settings()
        s.largeFileThresholdMB = 5
        s.oldFileMinimumMB = 1
        s.offloadDestination = isEmpty ? nil : nasFolder.path(percentEncoded: false)
        return s
    }
    /// The fixture's "Trash": review-tier items are moved here, never to the user's real Trash.
    public var trashFolder: URL { root.appending(path: "Trash", directoryHint: .isDirectory) }
    public var remover: any FileRemover { FolderTrashRemover(trashFolder: trashFolder) }
    public var historyLog: HistoryLog { HistoryLog(url: root.appending(path: "history.jsonl")) }
    public var settingsStore: SettingsStore { SettingsStore(url: root.appending(path: "settings.json")) }
    public var hibernationLog: HibernationLog { HibernationLog(url: root.appending(path: "hibernations.jsonl")) }
    /// The fixture's "NAS share" (reported as a mounted SMB volume by `nasProbe`) and local offload manifests.
    public var nasFolder: URL { root.appending(path: "NAS", directoryHint: .isDirectory) }
    public var offloadStore: OffloadStore { OffloadStore(directory: root.appending(path: "offloads", directoryHint: .isDirectory)) }
    public let nasProbe: FakeVolumeProbe

    /// Creates a fresh fixture tree. `scale` multiplies file sizes (tests use small ones).
    /// `empty` creates only the folders (no files, no projects, no NAS folder chosen).
    public static func create(in parent: URL = FileManager.default.temporaryDirectory, scale: Double = 1,
                              empty: Bool = false) throws -> FixtureWorld {
        let root = parent.appending(path: directoryPrefix + UUID().uuidString, directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let nas = root.standardizedFileURL.appending(path: "NAS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        let world = FixtureWorld(root: root.standardizedFileURL, home: home.standardizedFileURL, runner: SimulatedRunner(),
                                 isEmpty: empty, nasProbe: FakeVolumeProbe(root: nas))
        if empty {
            try world.settingsStore.save(world.settings)
        } else {
            try world.populate(scale: scale)
        }
        return world
    }

    /// Dev aid (`--fixture-lock-documents`): makes the fixture's ~/Documents unreadable, to see how the file rules
    /// report a folder macOS privacy protection keeps them out of. Only ever the fixture's own folder.
    public func lockDocuments() {
        chmod(home.appending(path: "Documents").path, 0)
    }

    public func unlockDocuments() {
        chmod(home.appending(path: "Documents").path, 0o755)
    }

    /// Removes the fixture tree (only ever a directory we created, recognised by its prefix).
    public func destroy() {
        guard root.lastPathComponent.hasPrefix(Self.directoryPrefix) else { return }
        unlockDocuments()
        // A scan or git query still running at quit can recreate entries mid-removal; retry briefly.
        for _ in 0..<5 {
            try? FileManager.default.removeItem(at: root)
            if !FileManager.default.fileExists(atPath: root.path) { return }
            usleep(100_000)
        }
    }

    private func populate(scale: Double) throws {
        let mb = { (n: Double) in max(1, Int(n * 1_000_000 * scale)) }
        let old = Date(timeIntervalSinceNow: -86400 * 120)
        let files: [(String, Int, Date?)] = [
            ("Library/Developer/Xcode/DerivedData/Telescope-abcdefgh/Build/Products/app.bin", mb(9), nil),
            ("Library/Developer/Xcode/DerivedData/Orbiter-ijklmnop/Index.noindex/store", mb(5), old),
            ("Library/Developer/Xcode/DerivedData/Capsule-qrstuvwx/Logs/build.log", mb(2), nil),
            (".npm/_cacache/content-v2/sha512/ab/blob", mb(7), nil),
            ("Library/Logs/Starman/starman.log", mb(1), old),
            ("Library/Logs/ground-control.log", mb(0.5), nil),
            (".nvm/versions/node/v18.20.4/bin/node", mb(4), old),
            (".nvm/versions/node/v22.11.0/bin/node", mb(4), nil),
            ("Library/pnpm/store/v10/files/00/blob", mb(6), nil),
            (".gradle/wrapper/dists/gradle-8.7-bin/gradle.zip", mb(3), old),
            (".gradle/wrapper/dists/gradle-8.10-bin/gradle.zip", mb(3), nil),
            ("Library/Developer/Xcode/Archives/2026-03-01/Telescope 1.0.xcarchive/Info.plist", mb(2), old),
        ]
        for (rel, bytes, date) in files {
            let url = home.appending(path: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
            if let date {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                try FileManager.default.setAttributes([.modificationDate: date],
                                                      ofItemAtPath: url.deletingLastPathComponent().path)
            }
        }
        try "v22.11.0\n".write(to: home.appending(path: ".nvm/alias/default", directoryHint: .notDirectory)
            .creatingParent(), atomically: true, encoding: .utf8)
        try populateProjects(mb: mb)
        try populateUserFiles(mb: mb)
        try populateApps()
        try settingsStore.save(settings)
    }

    /// Downloads / Movies / Desktop / Documents for the general-cleanup rules, including things that must
    /// never be listed (a git repo, a JS project, a Photos library, the TV app's media).
    private func populateUserFiles(mb: (Double) -> Int) throws {
        let day: Double = 86400
        let files: [(String, Int, Double)] = [  // path, bytes, days since last touched
            ("Downloads/Xcode_26.1.xip", mb(9), 60),
            ("Downloads/Starman-2.4.dmg", mb(3), 2),
            ("Downloads/fonts.zip", mb(0.4), 40),
            ("Downloads/Ziggy Stardust tour.mov", mb(12), 400),
            ("Downloads/Hunky Dory.app/Contents/MacOS/Hunky Dory", mb(6), 90),
            ("Downloads/Hunky Dory.app/Contents/Info.plist", 600, 90),
            ("Movies/Space Oddity (4K master).mov", mb(20), 3),
            ("Movies/Moonage/Moonage.prproj", mb(0.2), 30),
            ("Movies/Moonage/footage/A001.mp4", mb(7), 30),
            ("Movies/Moonage/Adobe Premiere Pro Audio Previews/x.PRV/cfa.bin", mb(6), 30),
            ("Movies/Photos Library.photoslibrary/originals/0/IMG_0001.heic", mb(15), 700),
            ("Movies/TV/Media/Movies/Labyrinth.m4v", mb(10), 900),
            ("Desktop/Screen Recording 2024-06-01.mov", mb(3), 500),
            ("Documents/Taxes 2019.pdf", mb(2), 2000),
            ("Documents/notes.txt", 2000, 3000),
            ("Documents/Code/heliosphere/assets/render.bin", mb(15), 800),
            ("Documents/Code/heliosphere/.git/HEAD", 30, 800),
            ("Documents/launch-site/package.json", 40, 800),
            ("Documents/launch-site/public/hero.mp4", mb(8), 800),
        ]
        for (rel, bytes, days) in files {
            let url = home.appending(path: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
            let date = Date(timeIntervalSinceNow: -days * day)
            try FileTimes.set(url, modified: date, added: date)
        }
        let app = home.appending(path: "Downloads/Hunky Dory.app")
        try Self.backdate(app, to: Date(timeIntervalSinceNow: -90 * day))
        try FileTimes.set(app, modified: Date(timeIntervalSinceNow: -90 * day), added: Date(timeIntervalSinceNow: -90 * day))
    }

    /// An installed app (with a nested helper) and Library data of installed, removed and unknowable apps.
    private func populateApps() throws {
        let day: Double = 86400
        func plist(_ rel: String, _ id: String) throws {
            let url = home.appending(path: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                .write(to: url)
        }
        try plist("Applications/Starman.app/Contents/Info.plist", "com.ziggy.starman")
        try plist("Applications/Starman.app/Contents/Library/LoginItems/Launcher.app/Contents/Info.plist", "net.spiders.starman-launcher")

        // (folder, days since touched)
        let data: [(String, Double)] = [
            ("Library/Application Support/com.ziggy.starman", 200),            // installed
            ("Library/Application Support/net.spiders.starman-launcher", 200), // nested helper of an installed app
            ("Library/Application Support/com.ziggy.legacy-visualiser", 200),  // same vendor as an installed app: unsure
            ("Library/Application Support/com.mars.spiders", 200),             // removed app
            ("Library/Caches/com.mars.spiders", 200),
            ("Library/HTTPStorages/com.mars.spiders", 200),
            ("Library/Containers/com.mars.spiders/Data/Library/Preferences", 200),
            ("Library/Application Support/org.lowfi.soundandvision", 400),     // removed app, support only
            ("Library/Application Support/com.apple.fixture-helper", 400),    // Apple's: never
            ("Library/Caches/com.vercel.cli", 400),                            // CLI tooling: never
            ("Library/Application Support/com.heroes.justforoneday", 3),      // touched recently: never
            ("Library/Application Support/io.stellar.desktop", 300),           // the user's own project (web/stellar)
        ]
        for (rel, _) in data {
            let dir = home.appending(path: rel, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: 20_000).write(to: dir.appending(path: "state.db"))
        }
        for (rel, days) in data {
            // Back-date the app's top folder (everything below it) after all files exist.
            let parts = rel.split(separator: "/")
            let top = home.appending(path: parts.prefix(3).joined(separator: "/"), directoryHint: .isDirectory)
            try Self.backdate(top, to: Date(timeIntervalSinceNow: -days * day))
        }
    }

    /// Sets the modification date of a folder and everything in it.
    static func backdate(_ dir: URL, to date: Date) throws {
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in e {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
    }

    /// Relative paths (under `projectsRoot`) of the fixture projects.
    public static let projectPaths = [
        "web/stellar", "web/acme-notes/acme-notes.reactnative", "[02] clients/acme-web", "[03] tools/rusty",
    ]
    public var projectsRoot: URL { home.appending(path: "WebstormProjects", directoryHint: .isDirectory) }

    /// Fake projects under `~/WebstormProjects` (the default project root):
    /// - `web/stellar`: pnpm + Turborepo monorepo (git, pushed except one commit), stale. Strippable: node_modules ×3,
    ///   `.turbo`, `apps/web/.next`, `packages/ui/dist` (ignored). `.env.local` must survive.
    /// - `web/acme-notes/acme-notes.reactnative`: yarn React Native app (git, uncommitted changes, no remote), stale.
    ///   Strippable: node_modules, ios/Pods, ios/build, android/build, android/app/build, android/.gradle, .expo.
    /// - `[02] clients/acme-web`: npm site (git), active. `build/` is tracked and `dist/` is neither ignored nor a
    ///   known output, so both are kept; only node_modules is strippable.
    /// - `[03] tools/rusty`: Cargo project without git, stale. Strippable: target.
    private func populateProjects(mb: (Double) -> Int) throws {
        let root = projectsRoot
        let longAgo = Date(timeIntervalSinceNow: -86400 * 200)
        let monthsAgo = Date(timeIntervalSinceNow: -86400 * 150)
        let recently = Date(timeIntervalSinceNow: -86400 * 5)

        func write(_ base: URL, _ files: [(String, Any)]) throws {
            for (rel, content) in files {
                let url = base.appending(path: rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let n = content as? Int {
                    try Data(count: n).write(to: url)
                } else {
                    try Data(String(describing: content).utf8).write(to: url)
                }
            }
        }

        // web/stellar — pnpm/turbo monorepo.
        let stellar = root.appending(path: "web/stellar")
        try write(stellar, [
            ("package.json", #"{"name":"stellar","private":true,"packageManager":"pnpm@9.12.0","devDependencies":{"turbo":"2.1.0"}}"#),
            ("pnpm-lock.yaml", "lockfileVersion: '9.0'\n"),
            ("pnpm-workspace.yaml", "packages:\n  - apps/*\n  - packages/*\n"),
            ("turbo.json", "{}\n"),
            (".gitignore", "node_modules\n.next\ndist\n.turbo\n.env*.local\n"),
            (".env.local", "API_KEY=fixture-only\n"),
            ("README.md", "# Stellar\n"),
            ("apps/web/package.json", #"{"name":"web","dependencies":{"next":"15.0.0"}}"#),
            ("apps/web/app/page.tsx", "export default function Page() { return null }\n"),
            ("apps/web/.next/cache/webpack.pack", mb(6)),
            ("apps/web/node_modules/.bin/next", mb(0.2)),
            ("packages/ui/package.json", #"{"name":"ui","devDependencies":{"tsup":"8.0.0"}}"#),
            ("packages/ui/src/index.ts", "export const ui = 1\n"),
            ("packages/ui/dist/index.js", mb(1)),
            ("packages/ui/node_modules/.bin/tsup", mb(0.2)),
            ("node_modules/.pnpm/react@19.0.0/node_modules/react/index.js", mb(8)),
            (".turbo/cache/0123abcd.tar.zst", mb(3)),
        ])
        let stellarRemote = root.deletingLastPathComponent().appending(path: "remotes/stellar.git")

        // web/acme-notes/acme-notes.reactnative — React Native app.
        let rn = root.appending(path: "web/acme-notes/acme-notes.reactnative")
        try write(rn, [
            ("package.json", #"{"name":"acme-notes","dependencies":{"react-native":"0.76.0","expo":"52.0.0"}}"#),
            ("yarn.lock", "# yarn lockfile v1\n"),
            (".gitignore", "node_modules/\n.expo/\nios/Pods/\nios/build/\nandroid/build/\nandroid/app/build/\nandroid/.gradle/\n"),
            ("App.tsx", "export default function App() { return null }\n"),
            ("ios/Podfile", "platform :ios, '15.1'\n"),
            ("ios/Podfile.lock", "PODFILE CHECKSUM: fixture\n"),
            ("ios/acme-notes.xcodeproj/project.pbxproj", "// fixture\n"),
            ("ios/Pods/hermes-engine/hermes.xcframework", mb(7)),
            ("ios/build/Build/Products/acme-notes.app", mb(2)),
            ("android/build.gradle", "// fixture\n"),
            ("android/settings.gradle", "// fixture\n"),
            ("android/app/build.gradle", "// fixture\n"),
            ("android/app/src/main/AndroidManifest.xml", "<manifest/>\n"),
            ("android/app/build/outputs/apk/debug/app-debug.apk", mb(5)),
            ("android/build/reports/problems.html", mb(0.1)),
            ("android/.gradle/8.10/fileHashes/fileHashes.bin", mb(1)),
            ("node_modules/react-native/index.js", mb(9)),
            (".expo/devices.json", "{}\n"),
        ])

        // [02] clients/acme-web — active npm site with a tracked build folder.
        let site = root.appending(path: "[02] clients/acme-web")
        try write(site, [
            ("package.json", #"{"name":"acme-web","scripts":{"build":"node scripts/build.js"}}"#),
            ("package-lock.json", "{}\n"),
            (".gitignore", "node_modules/\n"),
            ("index.html", "<!doctype html>\n"),
            ("build/deploy.sh", "#!/bin/sh\necho deploy\n"),
            ("scripts/build.js", "console.log('build')\n"),
            ("node_modules/lodash/lodash.js", mb(4)),
        ])

        // [03] tools/rusty — Cargo project, no git.
        let rusty = root.appending(path: "[03] tools/rusty")
        try write(rusty, [
            ("Cargo.toml", "[package]\nname = \"rusty\"\n"),
            ("Cargo.lock", "version = 3\n"),
            ("src/main.rs", "fn main() {}\n"),
            ("target/debug/rusty", mb(3)),
        ])

        // Git history (real git, but only ever inside this temp folder, with the user's config switched off).
        if FixtureGit.available {
            try FixtureGit.commitAll(stellar, date: longAgo)
            try FixtureGit.run(["init", "-q", "--bare", stellarRemote.path], in: root.deletingLastPathComponent(), date: longAgo)
            try FixtureGit.run(["remote", "add", "origin", stellarRemote.path], in: stellar, date: longAgo)
            try FixtureGit.run(["push", "-q", "origin", "main"], in: stellar, date: longAgo)
            try write(stellar, [("README.md", "# Stellar\n\nNotes.\n")])
            try FixtureGit.commitAll(stellar, date: longAgo, message: "notes")

            try FixtureGit.commitAll(rn, date: monthsAgo)
            try write(rn, [("App.tsx", "export default function App() { return 'wip' }\n"), ("notes.md", "todo\n")])

            // Commit the build folder deliberately (some projects do).
            try FixtureGit.commitAll(site, date: recently)
            try write(site, [("dist/bundle.js", mb(0.5))])
        }
        try Self.setModificationDates(in: stellar, to: longAgo)
        try Self.setModificationDates(in: rn, to: monthsAgo)
        try Self.setModificationDates(in: rusty, to: longAgo)
    }

    /// Back-dates every file (not `.git`) so the project looks inactive.
    static func setModificationDates(in dir: URL, to date: Date) throws {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e {
            if url.lastPathComponent == ".git" { e.skipDescendants(); continue }
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }
}

/// Runs git for building fixtures only: in a given temp directory, isolated from the user's git config.
public enum FixtureGit {
    public static var available: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    public static let isolatedEnvironment: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
    ]

    public static func commitAll(_ dir: URL, date: Date, message: String = "fixture") throws {
        if !FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) {
            try run(["init", "-q", "-b", "main"], in: dir, date: date)
        }
        try run(["add", "-A"], in: dir, date: date)
        try run(["commit", "-q", "-m", message], in: dir, date: date)
    }

    public static func run(_ args: [String], in dir: URL, date: Date) throws {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/git")
        p.arguments = ["-c", "user.name=CloudSpace", "-c", "user.email=majortom@example.invalid", "-c", "commit.gpgsign=false"] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment.merging(isolatedEnvironment) { _, new in new }
        let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
        env["GIT_AUTHOR_DATE"] = stamp
        env["GIT_COMMITTER_DATE"] = stamp
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "FixtureGit", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed in \(dir.path)"])
        }
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

/// A command runner that never runs anything: it records the call and reports success.
public final class SimulatedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    public init() {}

    public func run(_ argv: [String], timeout: TimeInterval) async -> CommandResult? {
        lock.withLock { calls.append(argv) }
        if argv.starts(with: ["tmutil", "listlocalsnapshots"]) {
            return CommandResult(exitCode: 0, stdout: Data("com.apple.TimeMachine.2026-11-14-090000.local\n".utf8))
        }
        return CommandResult(exitCode: 0, stdout: Data())
    }

    public var recordedCalls: [[String]] { lock.withLock { calls } }
}

/// Rules mirroring the real catalogue's shapes (per-item, whole-folder, protected, flagged, actions, report-only),
/// but rooted in the fixture home.
public enum FixtureRules {
    /// The M5 rules are the real ones: everything they look at is relative to the fixture home, and the fixture
    /// context only knows the fixture's own `Applications` folder.
    public static var all: [Rule] {
        [derivedData, npm, logs, nodeVersions, pnpm, gradle, archives, snapshots]
            + FilesRules.all + [OrphanedAppData.rule]
    }

    static let derivedData = Rule(
        id: "fx-derived-data", title: "Xcode DerivedData (fixture)", category: .xcode, tier: .safe,
        impact: "Xcode rebuilds each project from scratch and re-indexes it the next time you open it.",
        recovery: "Automatically on next build.", regenCost: "A full rebuild per project.",
        method: .delete,
        baseDirectories: { [$0.path("Library/Developer/Xcode/DerivedData")] },
        resolve: { ctx in
            childItems(ctx.path("Library/Developer/Xcode/DerivedData")).map { item in
                var item = item
                if item.displayName.hasPrefix("Orbiter") {
                    item.isFlagged = true
                    item.note = "Source project no longer exists"
                }
                return item
            }
        })

    static let npm = Rule(
        id: "fx-npm", title: "npm cache (fixture)", category: .javascript, tier: .safe,
        impact: "npm re-downloads packages on the next install that misses its cache.",
        recovery: "Automatically on next npm install.", regenCost: "Slower first installs.",
        method: .delete,
        baseDirectories: { [$0.path(".npm")] },
        resolve: { ctx in wholeItem(ctx.path(".npm/_cacache"), name: "_cacache") })

    static let logs = Rule(
        id: "fx-logs", title: "Logs (fixture)", category: .system, tier: .safe,
        impact: "Old app logs are gone.", recovery: "Apps write new logs as they run.", regenCost: "None.",
        method: .deleteContents,
        baseDirectories: { [$0.path("Library/Logs")] },
        resolve: { ctx in childItems(ctx.path("Library/Logs"), directoriesOnly: false) })

    static let nodeVersions = Rule(
        id: "fx-node-versions", title: "Node versions (fixture)", category: .javascript, tier: .costsTime,
        impact: "Projects pinned to a removed Node version fail until you reinstall it.",
        recovery: "nvm install <version>", regenCost: "~1 min download per version.",
        method: .delete,
        baseDirectories: { [$0.path(".nvm/versions/node")] },
        resolve: { ctx in
            let active = FS.readText(ctx.path(".nvm/alias/default"))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return childItems(ctx.path(".nvm/versions/node")).map { item in
                var item = item
                if item.displayName == active {
                    item.isProtected = true
                    item.note = "Default nvm version — never offered"
                }
                return item
            }
        })

    static let pnpm = Rule(
        id: "fx-pnpm", title: "pnpm store (fixture)", category: .javascript, tier: .costsTime,
        impact: "Every project re-downloads its packages on the next pnpm install.",
        recovery: "pnpm install in each project.", regenCost: "Re-download the whole store.",
        method: .delete,
        baseDirectories: { [$0.path("Library/pnpm/store")] },
        resolve: { ctx in wholeItem(ctx.path("Library/pnpm/store"), name: "store") },
        actions: { _, items in
            guard !items.isEmpty else { return [] }
            return [RuleAction(id: "prune", title: "Prune unreferenced packages", command: ["pnpm", "store", "prune"],
                               tier: .safe, explanation: "Removes only packages no project references (simulated in fixture mode).")]
        })

    static let gradle = Rule(
        id: "fx-gradle", title: "Gradle wrapper dists (fixture)", category: .android, tier: .costsTime,
        impact: "Projects using a removed Gradle version download it again on their next build.",
        recovery: "Automatically on next ./gradlew run.", regenCost: "~150 MB download per version.",
        method: .delete,
        baseDirectories: { [$0.path(".gradle/wrapper/dists")] },
        resolve: { ctx in childItems(ctx.path(".gradle/wrapper/dists")) })

    static let archives = Rule(
        id: "fx-archives", title: "Xcode Archives (fixture)", category: .xcode, tier: .review,
        impact: "You can no longer re-symbolicate crash logs or re-export these builds.",
        recovery: "None, unless you kept a copy.", regenCost: "Not recoverable.",
        // The real rule trashes; the fixture deletes so testing never fills the user's real Trash.
        method: .delete,
        baseDirectories: { [$0.path("Library/Developer/Xcode/Archives")] },
        resolve: { ctx in
            FS.children(of: ctx.path("Library/Developer/Xcode/Archives"), directoriesOnly: true).flatMap {
                childItems($0)
            }
        })

    static let snapshots = Rule(
        id: "fx-snapshots", title: "Local snapshots (fixture)", category: .system, tier: .review,
        impact: "Report only.", recovery: "Time Machine creates new ones hourly.", regenCost: "Lose local restore points.",
        method: .reportOnly,
        baseDirectories: { _ in [] },
        resolve: { ctx in
            guard let r = await ctx.runner.run(["tmutil", "listlocalsnapshots", "/"], timeout: 5), r.succeeded else { return [] }
            return r.stdoutString.split(whereSeparator: \.isNewline).map { Item(id: String($0), displayName: String($0), path: nil) }
        },
        actions: { _, items in
            items.isEmpty ? [] : [RuleAction(id: "delete-all", title: "Delete all local snapshots",
                                             command: ["tmutil", "deletelocalsnapshots", "/"], tier: .review,
                                             explanation: "Run it yourself in Terminal.", runnable: false)]
        })
}
