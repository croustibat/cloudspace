import Foundation

/// How painful it is to delete something.
public enum Tier: String, Codable, Sendable, CaseIterable, Comparable {
    /// Regenerates automatically, no user action needed.
    case safe
    /// Works again after a re-download / rebuild / re-setup the user will notice.
    case costsTime
    /// User data or anything not automatically recoverable.
    case review

    public var label: String {
        switch self {
        case .safe: "safe"
        case .costsTime: "costs time"
        case .review: "review"
        }
    }

    private var order: Int {
        switch self {
        case .safe: 0
        case .costsTime: 1
        case .review: 2
        }
    }

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.order < rhs.order }
}

public enum RuleCategory: String, Codable, Sendable, CaseIterable {
    case xcode, android, javascript, packageManagers, ides, containers, system, projects, files

    public var title: String {
        switch self {
        case .xcode: "Xcode & Simulators"
        case .android: "Android"
        case .javascript: "JavaScript"
        case .packageManagers: "Package managers"
        case .ides: "IDEs"
        case .containers: "Containers"
        case .system: "System"
        case .projects: "Projects"
        case .files: "Files & leftovers"
        }
    }
}

/// How an item is removed.
public enum CleanMethod: Codable, Sendable, Hashable {
    /// Delete outright (caches: trashing a cache frees nothing).
    case delete
    /// Delete everything inside the folder and keep the (empty) folder, for folders an app expects to exist
    /// (e.g. `~/Library/Logs/<App>`). A file item is simply deleted.
    case deleteContents
    /// Move to the Trash (review-tier user data).
    case trash
    /// Run the owning tool's command (argv, no shell).
    case command([String])
    /// Nothing is cleaned; the rule/item is informational only.
    case reportOnly

    public var summary: String {
        switch self {
        case .delete: "delete"
        case .deleteContents: "delete contents (keeps the folder)"
        case .trash: "move to Trash"
        case .command(let argv): "run `\(argv.joined(separator: " "))`"
        case .reportOnly: "report only"
        }
    }
}

/// A concrete thing a rule found, individually selectable.
public struct Item: Codable, Sendable, Hashable, Identifiable {
    /// Stable within a rule (usually the path, or a tool identifier such as a simulator UDID).
    public var id: String
    public var displayName: String
    /// The path that is deleted/trashed. Nil for tool-managed items (e.g. simulator runtimes).
    public var path: URL?
    /// Extra paths removed together with `path` (e.g. an AVD's `.ini` next to its `.avd`). Validated the same way.
    public var companionPaths: [URL]
    /// Allocated bytes on disk (inode de-duplicated within a scan). Nil until sized.
    public var size: Int64?
    /// Newest content-modification/access date across the item's top level.
    public var lastUsed: Date?
    public var note: String?
    /// Overrides the rule's method for this item.
    public var methodOverride: CleanMethod?
    /// Protected items are shown but can never be cleaned (active Node version, default toolchain, …).
    public var isProtected: Bool
    /// Highlighted as a good candidate (orphaned DerivedData, unused system image, old IDE version, …).
    public var isFlagged: Bool

    /// Scanned items carry their effective method in `methodOverride`.
    public var isCleanable: Bool { !isProtected && methodOverride != .reportOnly }

    public init(
        id: String? = nil,
        displayName: String,
        path: URL?,
        companionPaths: [URL] = [],
        size: Int64? = nil,
        lastUsed: Date? = nil,
        note: String? = nil,
        methodOverride: CleanMethod? = nil,
        isProtected: Bool = false,
        isFlagged: Bool = false
    ) {
        self.id = id ?? path?.path ?? displayName
        self.displayName = displayName
        self.path = path
        self.companionPaths = companionPaths
        self.size = size
        self.lastUsed = lastUsed
        self.note = note
        self.methodOverride = methodOverride
        self.isProtected = isProtected
        self.isFlagged = isFlagged
    }
}

/// A rule-level action that isn't tied to a single item (e.g. `pnpm store prune`, `simctl delete unavailable`).
public struct RuleAction: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var command: [String]
    public var tier: Tier
    public var explanation: String
    /// If false the command is only shown to the user (needs admin rights, or deliberately hands-off).
    public var runnable: Bool

    public init(id: String, title: String, command: [String], tier: Tier, explanation: String, runnable: Bool = true) {
        self.id = id
        self.title = title
        self.command = command
        self.tier = tier
        self.explanation = explanation
        self.runnable = runnable
    }

    public var commandLine: String { command.map(shellQuote).joined(separator: " ") }
}

func shellQuote(_ s: String) -> String {
    if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@+,".contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Everything a resolver needs; injectable so tests run against a fixture home.
public struct RuleContext: Sendable {
    public var home: URL
    /// System paths that rules may touch besides the home folder.
    public var allowedSystemRoots: [URL]
    public var runner: any CommandRunner
    public var environment: [String: String]
    public var settings: Settings
    /// Where installed apps are looked up (orphaned app data). Defaults to the real system only when `home`
    /// is the real home folder; fixture and test homes only ever see their own `Applications` folder.
    public var appSources: AppInventorySource

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowedSystemRoots: [URL] = [URL(filePath: "/Library/Developer/CoreSimulator")],
        runner: any CommandRunner = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: Settings = Settings(),
        appSources: AppInventorySource? = nil
    ) {
        self.home = home.standardizedFileURL
        self.allowedSystemRoots = allowedSystemRoots
        self.runner = runner
        self.environment = environment
        self.settings = settings
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        self.appSources = appSources ?? (self.home.path == realHome.path
            ? .system(home: self.home)
            : .only([self.home.appending(path: "Applications", directoryHint: .isDirectory)]))
    }

    public func path(_ relative: String) -> URL {
        home.appending(path: relative, directoryHint: .inferFromPath)
    }
}

public struct Rule: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var category: RuleCategory
    public var tier: Tier
    /// Plain English: what actually happens to me if I delete this.
    public var impact: String
    /// How it comes back.
    public var recovery: String
    /// E.g. "~10 min full rebuild per project".
    public var regenCost: String
    /// Default method for items; items may override.
    public var method: CleanMethod
    /// Directories the rule's items must live under (used for symlink-escape validation).
    public var baseDirectories: @Sendable (RuleContext) -> [URL]
    public var resolve: @Sendable (RuleContext) async throws -> [Item]
    /// Rule-level actions (computed after resolution, since they can depend on what was found).
    public var actions: @Sendable (RuleContext, [Item]) -> [RuleAction]
    /// Items may only ever be moved to the Trash, never deleted outright, whatever an item or method says.
    public var trashOnly: Bool

    public init(
        id: String,
        title: String,
        category: RuleCategory,
        tier: Tier,
        impact: String,
        recovery: String,
        regenCost: String,
        method: CleanMethod,
        baseDirectories: @escaping @Sendable (RuleContext) -> [URL],
        resolve: @escaping @Sendable (RuleContext) async throws -> [Item],
        actions: @escaping @Sendable (RuleContext, [Item]) -> [RuleAction] = { _, _ in [] },
        trashOnly: Bool = false
    ) {
        self.trashOnly = trashOnly
        self.id = id
        self.title = title
        self.category = category
        self.tier = tier
        self.impact = impact
        self.recovery = recovery
        self.regenCost = regenCost
        self.method = method
        self.baseDirectories = baseDirectories
        self.resolve = resolve
        self.actions = actions
    }

    public func method(for item: Item) -> CleanMethod { item.methodOverride ?? method }

    /// Trash-only rules (and every rule in the Files category) can never hard-delete. The engine enforces it,
    /// and also refuses their paths inside projects, repositories and packages.
    public var isTrashOnly: Bool { trashOnly || category == .files }

    /// Resolves the rule; a partial resolution (some folders unreadable) still yields its items.
    public func resolveItems(_ context: RuleContext) async -> (items: [Item], error: String?, denied: [String]) {
        do {
            return (try await resolve(context), nil, [])
        } catch let partial as PartialResolution {
            return (partial.items, partial.message, partial.deniedPaths)
        } catch {
            return ([], String(describing: error), [])
        }
    }
}

/// Thrown by a resolver that found items but couldn't read everything (e.g. macOS privacy protection on
/// ~/Documents). The scanner shows the items *and* the message; the clean engine uses the items.
public struct PartialResolution: Error, Sendable, CustomStringConvertible {
    public var items: [Item]
    public var message: String
    /// Folders that couldn't be read (display paths such as `~/Documents`).
    public var deniedPaths: [String]

    public init(items: [Item], message: String, deniedPaths: [String]) {
        self.items = items
        self.message = message
        self.deniedPaths = deniedPaths
    }

    public var description: String { message }
}

/// The outcome of scanning one rule.
public struct RuleResult: Sendable, Codable, Identifiable {
    public var id: String { ruleID }
    public var ruleID: String
    public var items: [Item]
    public var actions: [RuleAction]
    public var duration: TimeInterval
    public var error: String?
    public var scannedAt: Date
    /// Folders the rule couldn't read because macOS privacy protection denied access (empty when all was readable).
    public var deniedPaths: [String] = []

    public init(ruleID: String, items: [Item], actions: [RuleAction], duration: TimeInterval, error: String?,
                scannedAt: Date, deniedPaths: [String] = []) {
        self.ruleID = ruleID
        self.items = items
        self.actions = actions
        self.duration = duration
        self.error = error
        self.scannedAt = scannedAt
        self.deniedPaths = deniedPaths
    }

    /// Bytes across items Major Tom can actually clean (not protected, not report-only).
    public var reclaimableSize: Int64 {
        items.filter(\.isCleanable).reduce(0) { $0 + ($1.size ?? 0) }
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
}
