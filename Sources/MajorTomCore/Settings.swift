import Foundation

/// User settings, persisted as JSON in Application Support.
public struct Settings: Codable, Sendable, Equatable {
    /// Format version of the settings file. Files without one were written before the portability changes
    /// (version 1), when an unset offload destination meant `/Volumes/MajorTom` — see `init(from:)`.
    public static let currentVersion = 2
    /// The offload destination version-1 files implied when they didn't name one.
    public static let legacyOffloadDestination = "/Volumes/MajorTom"

    public var version: Int = Settings.currentVersion
    /// Folders under which projects live (M3). Paths with `~` are expanded against the home folder.
    /// Nil = not chosen by the user: the common project folders that exist are used (`ProjectRootDetector`).
    public var projectRoots: [String]?
    /// A project is stale after this many days without activity (M3).
    public var staleAfterDays: Int = 90
    /// Project paths never offered for hibernation (still listed).
    public var pinnedProjects: [String] = []
    /// Project paths hidden from the Projects list entirely.
    public var ignoredProjects: [String] = []
    /// Notify when free space drops below this many GB (M4).
    public var lowSpaceThresholdGB: Int = 20
    /// Post a notification when free space drops below the threshold (M4). Off until the user turns it on,
    /// because turning it on asks macOS for notification permission.
    public var lowSpaceNotifications: Bool = false
    /// Rule IDs hidden from scans.
    public var disabledRuleIDs: [String] = []
    /// Item paths the user never wants offered.
    public var ignoredPaths: [String] = []
    /// Weekly background rescan (M4).
    public var weeklyRescan: Bool = false
    /// Launch at login (M4).
    public var launchAtLogin: Bool = false
    /// NAS offload destination (M6): a folder on the mounted share. Nil = not chosen yet (offloading is off).
    public var offloadDestination: String?
    /// Bundle-ID prefixes of apps the user builds themselves: their Library folders are never called orphaned.
    /// (Folders named after projects under the project roots are recognised automatically as well.)
    public var ownBundleIDPrefixes: [String] = ["uk.co.tom-jordan."]
    /// Offloaded files up to this size (MB) are re-read from the NAS and compared by SHA-256; bigger ones by size
    /// plus a hash of their first and last 4 MiB (M6).
    public var offloadChecksumCapMB: Int = 1024
    /// iCloud Drive destination: free the local copy of an offloaded archive as soon as macOS reports it uploaded.
    public var offloadAutoEvict: Bool = true
    /// Files at least this big (MB, decimal) in Downloads/Movies/Desktop/Documents are listed as large (M5).
    public var largeFileThresholdMB: Int = 500
    /// Files not opened or changed for this many days are listed as old (M5)…
    public var oldFileDays: Int = 365
    /// …if they are at least this big (MB). Keeps the list to things worth reviewing.
    public var oldFileMinimumMB: Int = 50

    public init() {}

    public init(from decoder: any Decoder) throws {
        // Tolerant decoding: missing keys keep their defaults so old files keep working.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        let fileVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        version = Settings.currentVersion
        projectRoots = try c.decodeIfPresent([String].self, forKey: .projectRoots)
        staleAfterDays = try c.decodeIfPresent(Int.self, forKey: .staleAfterDays) ?? d.staleAfterDays
        pinnedProjects = try c.decodeIfPresent([String].self, forKey: .pinnedProjects) ?? d.pinnedProjects
        ignoredProjects = try c.decodeIfPresent([String].self, forKey: .ignoredProjects) ?? d.ignoredProjects
        lowSpaceThresholdGB = try c.decodeIfPresent(Int.self, forKey: .lowSpaceThresholdGB) ?? d.lowSpaceThresholdGB
        lowSpaceNotifications = try c.decodeIfPresent(Bool.self, forKey: .lowSpaceNotifications) ?? d.lowSpaceNotifications
        disabledRuleIDs = try c.decodeIfPresent([String].self, forKey: .disabledRuleIDs) ?? d.disabledRuleIDs
        ignoredPaths = try c.decodeIfPresent([String].self, forKey: .ignoredPaths) ?? d.ignoredPaths
        weeklyRescan = try c.decodeIfPresent(Bool.self, forKey: .weeklyRescan) ?? d.weeklyRescan
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        offloadDestination = try c.decodeIfPresent(String.self, forKey: .offloadDestination)
            ?? (fileVersion < 2 ? Settings.legacyOffloadDestination : nil)
        ownBundleIDPrefixes = try c.decodeIfPresent([String].self, forKey: .ownBundleIDPrefixes) ?? d.ownBundleIDPrefixes
        offloadChecksumCapMB = try c.decodeIfPresent(Int.self, forKey: .offloadChecksumCapMB) ?? d.offloadChecksumCapMB
        offloadAutoEvict = try c.decodeIfPresent(Bool.self, forKey: .offloadAutoEvict) ?? d.offloadAutoEvict
        largeFileThresholdMB = try c.decodeIfPresent(Int.self, forKey: .largeFileThresholdMB) ?? d.largeFileThresholdMB
        oldFileDays = try c.decodeIfPresent(Int.self, forKey: .oldFileDays) ?? d.oldFileDays
        oldFileMinimumMB = try c.decodeIfPresent(Int.self, forKey: .oldFileMinimumMB) ?? d.oldFileMinimumMB
    }

    public var largeFileThresholdBytes: Int64 { Int64(max(1, largeFileThresholdMB)) * 1_000_000 }
    public var oldFileMinimumBytes: Int64 { Int64(max(0, oldFileMinimumMB)) * 1_000_000 }
    public var oldFileAge: TimeInterval { TimeInterval(max(1, oldFileDays)) * 86400 }

    /// True when a change affects what the general-cleanup (M5) file rules list.
    public func fileRulesDiffer(from other: Settings) -> Bool {
        largeFileThresholdMB != other.largeFileThresholdMB || oldFileDays != other.oldFileDays
            || oldFileMinimumMB != other.oldFileMinimumMB || projectRoots != other.projectRoots
            || ownBundleIDPrefixes != other.ownBundleIDPrefixes
    }

    /// The low-space threshold in bytes (decimal GB, like the rest of the UI).
    public var lowSpaceThresholdBytes: Int64 { Int64(max(1, lowSpaceThresholdGB)) * 1_000_000_000 }

    /// Where offloads go; nil until the user chooses a folder.
    public var offloadDestinationURL: URL? {
        offloadDestination.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// True while the project roots are detected automatically (the user hasn't added or removed one).
    public var projectRootsAreAutomatic: Bool { projectRoots == nil }

    /// The project roots in use, as stored (`~/…`): the user's list, or the detected common folders.
    public func effectiveProjectRoots(home: URL) -> [String] {
        projectRoots ?? ProjectRootDetector.detect(home: home)
    }

    public func expandedProjectRoots(home: URL) -> [URL] {
        effectiveProjectRoots(home: home).map { expandTilde($0, home: home) }
    }
}

/// Finds the usual project folders when the user hasn't configured any.
public enum ProjectRootDetector {
    /// Folder names directly in the home folder (matched case-insensitively, using the name on disk).
    public static let homeFolderNames = [
        "WebstormProjects", "Projects", "Developer", "Code", "dev", "src", "repos", "workspace", "git", "GitHub",
        "IdeaProjects", "AndroidStudioProjects", "XcodeProjects", "PycharmProjects", "GolandProjects",
        "RiderProjects", "CLionProjects", "PhpstormProjects", "RubymineProjects",
    ]
    /// Deeper folders, checked as written.
    public static let nestedPaths = ["Documents/GitHub", "Documents/Projects"]

    /// The candidates that exist as real directories (symlinks aren't followed), as `~/…` paths, in list order.
    public static func detect(home: URL) -> [String] {
        let onDisk = DiskSizer.listDirectory(home.path(percentEncoded: false))
        var byLower: [String: String] = [:]
        for name in onDisk where byLower[name.lowercased()] == nil { byLower[name.lowercased()] = name }
        var out: [String] = []
        var seen: Set<String> = []
        for wanted in homeFolderNames {
            guard let name = byLower[wanted.lowercased()], !seen.contains(name.lowercased()),
                  FS.isDirectory(home.appending(path: name)) else { continue }
            seen.insert(name.lowercased())
            out.append("~/" + name)
        }
        for rel in nestedPaths where FS.isDirectory(home.appending(path: rel)) {
            out.append("~/" + rel)
        }
        return out
    }
}

func expandTilde(_ path: String, home: URL) -> URL {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
    return URL(filePath: path)
}

public enum AppSupport {
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/MajorTom", directoryHint: .isDirectory)
    }
}

public final class SettingsStore: Sendable {
    public let url: URL

    public init(url: URL = AppSupport.directory().appending(path: "settings.json")) {
        self.url = url
    }

    /// Missing or unreadable file -> defaults.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: url, options: .atomic)
    }
}
