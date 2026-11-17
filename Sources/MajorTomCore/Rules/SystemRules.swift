import Foundation

public struct RuleError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

enum SystemRules {
    static var all: [Rule] { [claudeDesktop, genericCaches, logs, trash, localSnapshots] }

    static let claudeDesktop = Rule(
        id: "claude-desktop-data",
        title: "Claude desktop data",
        category: .system,
        tier: .review,
        impact: "Report only. This folder mixes caches with your local Claude state (sessions, extensions, VM bundles); deleting the wrong part signs you out or loses local data.",
        recovery: "Not applicable — Major Tom doesn't clean it in v1.",
        regenCost: "n/a",
        method: .reportOnly,
        baseDirectories: { [$0.path("Library/Application Support/Claude")] },
        resolve: { ctx in
            childItems(ctx.path("Library/Application Support/Claude"), directoriesOnly: false)
        }
    )

    /// Cache folders owned by more specific rules (excluded from the generic rule).
    static let coveredCacheNames: Set<String> = ["CocoaPods", "org.swift.swiftpm", "Homebrew", "JetBrains", "Yarn"]

    static let genericCaches = Rule(
        id: "app-caches",
        title: "App caches",
        category: .system,
        tier: .safe,
        impact: "Apps rebuild their caches as you use them: a bit slower on first launch, thumbnails/web content re-downloaded. Quit an app before clearing its cache. Apple's own caches are skipped, and caches of apps you've removed are listed under Leftovers from removed apps instead.",
        recovery: "Automatically, as each app runs.",
        regenCost: "Slightly slower first launch per app.",
        // Each app's cache folder is emptied but kept: apps (and their running helpers) expect it to exist.
        method: .deleteContents,
        baseDirectories: { [$0.path("Library/Caches")] },
        resolve: { ctx in
            // Caches of removed apps belong to the (review-tier, Trash-only) orphaned-app-data item instead.
            let claimed = await OrphanedAppData.find(ctx).claimedCachePaths
            return FS.children(of: ctx.path("Library/Caches"))
                .filter { !$0.lastPathComponent.hasPrefix("com.apple.") && !coveredCacheNames.contains($0.lastPathComponent) }
                .filter { !claimed.contains($0.path) }
                .map { Item(displayName: $0.lastPathComponent, path: $0, note: knownCacheNotes[$0.lastPathComponent]) }
        }
    )

    /// Caches whose loss costs more than a slower launch.
    static let knownCacheNotes: [String: String] = [
        "ms-playwright": "Playwright browser binaries — tests re-download them (`npx playwright install`)",
        "Cypress": "Cypress binary — re-downloaded on next `cypress` run",
        "cargo-xwin": "Windows SDK/CRT for cross-compiling — re-downloaded on next cargo xwin build",
        "dotslash": "DotSlash-fetched tool binaries — re-downloaded on demand",
        "Google": "includes Chrome and Android Studio caches",
        "pnpm": "pnpm metadata cache (not the package store)",
    ]

    static let logs = Rule(
        id: "logs",
        title: "Logs",
        category: .system,
        tier: .safe,
        impact: "Old app logs and crash reports are gone, so you can't look back at past crashes/errors. Apps start new logs immediately.",
        recovery: "New logs are written as apps run.",
        regenCost: "None.",
        // Each app's log folder is emptied but kept: running apps (e.g. a booted simulator) keep writing there.
        method: .deleteContents,
        baseDirectories: { [$0.path("Library/Logs")] },
        resolve: { ctx in childItems(ctx.path("Library/Logs"), directoriesOnly: false) }
    )

    static let trash = Rule(
        id: "trash",
        title: "Trash",
        category: .system,
        tier: .review,
        impact: "Items in the Trash are permanently deleted; you can no longer put them back.",
        recovery: "None (unless you have a Time Machine backup).",
        regenCost: "Not recoverable.",
        method: .delete,
        baseDirectories: { [$0.path(".Trash")] },
        resolve: { ctx in
            let dir = ctx.path(".Trash")
            guard FS.exists(dir) else { return [] }
            guard opendirReadable(dir) else {
                throw RuleError("~/.Trash is not readable — grant Full Disk Access to see its contents")
            }
            return childItems(dir, directoriesOnly: false)
        }
    )

    static func opendirReadable(_ url: URL) -> Bool {
        guard let d = opendir(url.path(percentEncoded: false)) else { return false }
        closedir(d)
        return true
    }

    static let localSnapshots = Rule(
        id: "local-snapshots",
        title: "Local Time Machine snapshots",
        category: .system,
        tier: .review,
        impact: "Local snapshots let Time Machine restore recent versions while the backup disk is away. macOS deletes them automatically when space runs low, but they make free space look smaller meanwhile.",
        recovery: "Time Machine creates new ones hourly while backups are on.",
        regenCost: "You lose the local restore points until the next backup.",
        method: .reportOnly,
        baseDirectories: { _ in [] },
        resolve: { ctx in
            guard let result = await ctx.runner.run(["tmutil", "listlocalsnapshots", "/"], timeout: 15), result.succeeded else { return [] }
            return result.stdoutString.split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.hasPrefix("com.apple.") }
                .map { name in
                    let date = name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                        .replacingOccurrences(of: ".local", with: "")
                    return Item(id: name, displayName: name, path: nil,
                                note: "delete with: tmutil deletelocalsnapshots \(date)")
                }
        },
        actions: { _, items in
            guard !items.isEmpty else { return [] }
            return [RuleAction(id: "delete-all", title: "Delete all local snapshots",
                               command: ["tmutil", "deletelocalsnapshots", "/"], tier: .review,
                               explanation: "Run it yourself in Terminal; may ask for admin rights.", runnable: false)]
        }
    )
}

public enum RuleCatalogue {
    public static var all: [Rule] {
        XcodeRules.all + JavaScriptRules.all + PackageManagerRules.all + AndroidRules.all
            + IDERules.all + ContainerRules.all + SystemRules.all + FilesRules.all + [OrphanedAppData.rule]
    }
}
