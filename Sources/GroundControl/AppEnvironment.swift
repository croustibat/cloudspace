import Foundation
import MajorTomCore

/// Everything the app talks to. `live()` is the real machine; `fixture(_:)` is a throwaway fake home
/// in the temp directory (nothing real is ever touched, commands are simulated).
public struct AppEnvironment: Sendable {
    public var rules: [Rule]
    public var context: RuleContext
    public var history: HistoryLog
    public var settingsStore: SettingsStore
    public var fixture: FixtureWorld?
    public var fullDiskAccess: @Sendable () -> FullDiskAccess.Status
    /// Read-only git queries for project discovery and hibernation.
    public var git: any CommandRunner
    public var hibernations: HibernationLog
    /// Deletes / moves to the Trash. Fixture mode moves "trashed" items into a folder inside the fixture.
    public var remover: any FileRemover
    /// "Is the offload destination a mounted network share?" Fixture mode fakes one inside the fixture folder.
    public var offloadProbe: any VolumeProbe
    /// Upload state / eviction for offloads kept in iCloud Drive.
    public var offloadCloud: any CloudStorage
    /// Local copies of offload manifests and their state.
    public var offloads: OffloadStore
    /// Test / dev seam (fixture `--fixture-slow-nas`): failure injection and throttling for offloads.
    public var offloadHooks: OffloadEngine.Hooks

    public var isFixture: Bool { fixture != nil }
    /// The folder whose volume the disk gauge and reclaimed-space measurement use.
    public var volumeURL: URL { context.home }

    public init(rules: [Rule], context: RuleContext, history: HistoryLog, settingsStore: SettingsStore,
                fixture: FixtureWorld? = nil,
                fullDiskAccess: @escaping @Sendable () -> FullDiskAccess.Status = { FullDiskAccess.status() },
                git: any CommandRunner = ProcessRunner(),
                hibernations: HibernationLog = HibernationLog(),
                remover: any FileRemover = SystemFileRemover(),
                offloadProbe: any VolumeProbe = LiveVolumeProbe(),
                offloadCloud: any CloudStorage = LiveCloudStorage(),
                offloads: OffloadStore = OffloadStore(),
                offloadHooks: OffloadEngine.Hooks = .init()) {
        self.remover = remover
        self.offloadProbe = offloadProbe
        self.offloadCloud = offloadCloud
        self.offloads = offloads
        self.offloadHooks = offloadHooks
        self.git = git
        self.hibernations = hibernations
        self.rules = rules
        self.context = context
        self.history = history
        self.settingsStore = settingsStore
        self.fixture = fixture
        self.fullDiskAccess = fullDiskAccess
    }

    public static func live() -> AppEnvironment {
        let store = SettingsStore()
        return AppEnvironment(rules: RuleCatalogue.all, context: RuleContext(settings: store.load()),
                              history: HistoryLog(), settingsStore: store)
    }

    public static func fixture(_ world: FixtureWorld) -> AppEnvironment {
        var git = ProcessRunner()
        git.environmentOverrides = FixtureGit.isolatedEnvironment
        return AppEnvironment(rules: world.rules, context: world.context, history: world.historyLog,
                              settingsStore: world.settingsStore, fixture: world, git: git,
                              hibernations: world.hibernationLog, remover: world.remover,
                              offloadProbe: world.nasProbe, offloads: world.offloadStore)
    }

    /// Fixture mode is on with `MAJORTOM_FIXTURE=1` or the `--fixture` launch argument.
    public static func wantsFixture(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--fixture") || ["1", "true", "yes"].contains(environment["MAJORTOM_FIXTURE"]?.lowercased() ?? "")
    }

    public static func fromProcess(arguments: [String] = CommandLine.arguments,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        if wantsFixture(arguments: arguments, environment: environment),
           let world = try? FixtureWorld.create(empty: arguments.contains("--fixture-empty")) {
            if arguments.contains("--fixture-lock-documents") { world.lockDocuments() }
            if arguments.contains("--fixture-nas-unmounted") { world.nasProbe.mounted = false }
            var env = AppEnvironment.fixture(world)
            if arguments.contains("--fixture-slow-nas") {
                // Dev aid for progress snapshots: ~2 MB/s, like a slow Wi-Fi link.
                env.offloadHooks.writeFault = { _ in usleep(400_000); return nil }
            }
            return env
        }
        return .live()
    }

    /// A project scanner over the configured roots (current settings).
    func projectScanner(settings: Settings) -> ProjectScanner {
        ProjectScanner(roots: settings.expandedProjectRoots(home: context.home), git: git)
    }

    /// The offload engine for the current settings (destination, checksum cap, project roots).
    public func offloadEngine(settings: Settings) -> OffloadEngine {
        var context = self.context
        context.settings = settings
        return OffloadEngine(destination: settings.offloadDestinationURL,
                             probe: offloadProbe, cloud: offloadCloud, context: context, rules: rules, git: git, store: offloads,
                             remover: remover, history: history, hooks: offloadHooks)
    }

    /// A clean engine using the current settings (project roots feed the path validator).
    func engine(settings: Settings) -> CleanEngine {
        var context = self.context
        context.settings = settings
        return CleanEngine(rules: rules, context: context, history: history, git: git, remover: remover)
    }
}

public struct DiskStatus: Sendable, Equatable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public static func measure(_ url: URL) -> DiskStatus {
        DiskStatus(totalBytes: VolumeInfo.totalBytes(at: url) ?? 0, freeBytes: VolumeInfo.availableBytes(at: url) ?? 0)
    }
}
