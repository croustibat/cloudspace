import CoreServices
import Darwin
import Foundation

/// M5 general cleanup over the user's own folders: large files, old files and installer leftovers in
/// `~/Downloads`, `~/Movies`, `~/Desktop` and `~/Documents`. Review tier, Trash only, never in Quick clean.
///
/// All three rules share one walk of those folders (concurrent resolutions join the walk in flight). Each file
/// lands in exactly one rule: installer leftovers first, then large files, then old files.
enum FilesRules {
    static var all: [Rule] { [largeFiles, oldFiles, installers] }

    static let largeFiles = Rule(
        id: "large-files",
        title: "Large files",
        category: .files,
        tier: .review,
        impact: "These are your own files: videos, disk images, exports, VMs, apps you dragged out of a download. Nothing regenerates them. Each goes to the Trash, so you can put it back until you empty it.",
        recovery: "Put Back from the Trash (until it's emptied), or restore from a backup.",
        regenCost: "Not recoverable once the Trash is emptied.",
        method: .trash,
        baseDirectories: { ctx in UserFilesWalker.folders.map { ctx.path($0) } },
        resolve: { ctx in try await resolve(ctx, bucket: .large) },
        trashOnly: true
    )

    static let oldFiles = Rule(
        id: "old-files",
        title: "Old files",
        category: .files,
        tier: .review,
        impact: "Your own files that haven't been opened or changed for a long time. Old doesn't mean unwanted — check each one. Each goes to the Trash, so you can put it back until you empty it.",
        recovery: "Put Back from the Trash (until it's emptied), or restore from a backup.",
        regenCost: "Not recoverable once the Trash is emptied.",
        method: .trash,
        baseDirectories: { ctx in UserFilesWalker.folders.map { ctx.path($0) } },
        resolve: { ctx in try await resolve(ctx, bucket: .old) },
        trashOnly: true
    )

    static let installers = Rule(
        id: "installer-leftovers",
        title: "Installer leftovers",
        category: .files,
        tier: .review,
        impact: "Disk images, installer packages and archives in Downloads. Once the app is installed they're usually dead weight, but a .zip may be the only copy of something — check before trashing.",
        recovery: "Download it again, or Put Back from the Trash.",
        regenCost: "A re-download if you need the installer again.",
        method: .trash,
        baseDirectories: { ctx in [ctx.path("Downloads")] },
        resolve: { ctx in try await resolve(ctx, bucket: .installer) },
        trashOnly: true
    )

    enum Bucket { case installer, large, old }

    static let walks = InFlight<UserFilesScan>()

    static func resolve(_ ctx: RuleContext, bucket: Bucket) async throws -> [Item] {
        let s = ctx.settings
        let key = [ctx.home.path, "\(s.largeFileThresholdMB)", "\(s.oldFileDays)", "\(s.oldFileMinimumMB)"]
            .joined(separator: "|") + s.effectiveProjectRoots(home: ctx.home).joined(separator: ":")
        let scan = await walks.value(key: key) {
            await offPool { UserFilesWalker.scan(home: ctx.home, settings: s) }
        }
        let now = Date()
        var mounted: Set<String> = []
        if bucket == .installer, scan.candidates.contains(where: { $0.isInstaller }) {
            mounted = await mountedDiskImages(ctx.runner)
        }
        let items = scan.candidates
            .filter { self.bucket(of: $0, settings: s, now: now) == bucket }
            .map { item(for: $0, bucket: bucket, settings: s, now: now, mounted: mounted) }

        let relevantDenied = scan.denied.filter { bucket != .installer || $0 == "~/Downloads" }
        if !relevantDenied.isEmpty {
            throw PartialResolution(items: items, message: deniedMessage(relevantDenied), deniedPaths: relevantDenied)
        }
        return items
    }

    static func bucket(of c: FileCandidate, settings: Settings, now: Date) -> Bucket? {
        if c.isInstaller { return .installer }
        if c.bytes >= settings.largeFileThresholdBytes { return .large }
        if c.bytes >= settings.oldFileMinimumBytes, now.timeIntervalSince(c.lastUsed) >= settings.oldFileAge { return .old }
        return nil
    }

    static func item(for c: FileCandidate, bucket: Bucket, settings: Settings, now: Date, mounted: Set<String>) -> Item {
        var parts = [c.location]
        if let kind = c.packageKind { parts.append("\(kind) — counted as one item") }
        if let app = c.mediaProject { parts.append("media of a \(app) project") }
        let idle = now.timeIntervalSince(c.lastUsed)
        var flagged = false
        var protected = false
        switch bucket {
        case .large:
            if idle >= settings.oldFileAge, c.mediaProject == nil {
                flagged = true
                parts.append("untouched for over \(settings.oldFileDays) days")
            }
        case .old:
            break
        case .installer:
            if mounted.contains(c.url.path) {
                protected = true
                parts.append("mounted right now — eject it first")
            } else if idle >= 30 * 86400 {
                flagged = true
            }
        }
        return Item(displayName: c.url.lastPathComponent, path: c.url, size: c.bytes, lastUsed: c.lastUsed,
                    note: parts.joined(separator: " · "), methodOverride: .trash, isProtected: protected,
                    isFlagged: flagged)
    }

    static func deniedMessage(_ denied: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: denied)
        return "macOS privacy protection kept CloudSpace out of \(list), so files there aren't listed. Allow access in System Settings → Privacy & Security → Files & Folders (or Full Disk Access), then rescan."
    }

    /// Disk images attached right now (`hdiutil info`), so a mounted installer is never offered.
    static func mountedDiskImages(_ runner: any CommandRunner) async -> Set<String> {
        guard let r = await runner.run(["hdiutil", "info", "-plist"], timeout: 10), r.succeeded,
              let plist = (try? PropertyListSerialization.propertyList(from: r.stdout, format: nil)) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { $0["image-path"] as? String })
    }
}

/// What counts as a project, package or app-managed library when looking through the user's folders.
public enum UserFilesPolicy {
    /// App-managed libraries: never listed, never trashed, not even as one item.
    static let managedLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "theater", "fcpbundle", "lrlibrary", "lrdata", "photoboothlibrary", "dvdproj",
    ]
    /// Files that are an app's database: never listed even when big.
    static let neverListFileExtensions: Set<String> = ["lrcat", "lrcat-wal", "itl", "musicdb", "itdb"]
    /// Packages that mean "this folder is source code" — the folder is skipped like a project.
    static let projectPackageExtensions: Set<String> = ["xcodeproj", "xcworkspace", "playground", "swiftpm"]
    /// Directory packages listed as a single item (their contents never are).
    static let knownPackageExtensions: Set<String> = [
        "app", "xcarchive", "bundle", "framework", "plugin", "kext", "appex", "pkg", "mpkg", "sparsebundle",
        "rtfd", "pages", "numbers", "key", "logicx", "band", "utm", "pvm", "vmwarevm", "docarchive", "dsym",
        "workflow", "prefpane", "saver", "mdimporter", "qlgenerator", "component", "vst", "vst3", "scriv",
        "imovieproject", "fcpxml", "sketch", "graffle", "oo3", "xcresult", "xcappdata",
    ]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip"]
    /// Project files of video/audio editors. Media next to them is linked from the project, so it is listed with
    /// a warning and never flagged.
    static let mediaProjectExtensions: [String: String] = [
        "prproj": "Premiere Pro", "aep": "After Effects", "drp": "DaVinci Resolve", "veg": "Vegas",
        "cmproj": "Camtasia", "screenflow": "ScreenFlow", "motn": "Motion", "ptx": "Pro Tools", "als": "Ableton Live",
    ]
    /// Render caches inside editor project folders: regenerated by the editor, meaningless names, never listed.
    static let editorCacheFolders: Set<String> = [
        "Adobe Premiere Pro Audio Previews", "Adobe Premiere Pro Video Previews", "Adobe Premiere Pro Auto-Save",
        "Media Cache", "Media Cache Files", "Peak Files", "CacheClip", "ProxyMedia", "Render Files", "Transcoded Media",
    ]

    public static func isManagedLibrary(name: String) -> Bool {
        managedLibraryExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A known package extension, or any directory macOS itself treats as a package.
    public static func isPackage(name: String, path: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if knownPackageExtensions.contains(ext) || managedLibraryExtensions.contains(ext)
            || projectPackageExtensions.contains(ext) { return true }
        guard FS.isDirectory(URL(filePath: path)) else { return false }
        return (try? URL(filePath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    /// A git repository or a folder with a project marker (`package.json`, `Package.swift`, `*.xcodeproj`, …).
    public static func isProjectDirectory(_ path: String) -> Bool {
        isProject(names: Set(DiskSizer.listDirectory(path)))
    }

    static func isProject(names: Set<String>) -> Bool {
        names.contains(".git") || !Walk.markers(in: names).isEmpty
            || names.contains { projectPackageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }
}

struct FileCandidate: Sendable {
    var url: URL
    /// e.g. "Downloads" or "Documents/Work/2023".
    var location: String
    var bytes: Int64
    /// e.g. "app bundle" for packages listed as one item.
    var packageKind: String?
    /// The editor whose project folder this sits in ("Premiere Pro"), if any.
    var mediaProject: String? = nil
    var isInstaller: Bool
    var modified: Date
    /// Newest of modification, Spotlight's "last opened" and the date it was added to its folder.
    var lastUsed: Date
}

struct UserFilesScan: Sendable {
    var candidates: [FileCandidate] = []
    /// Folders macOS privacy protection kept us out of, as display paths (`~/Documents`).
    var denied: [String] = []
    /// Project folders that were skipped (display paths).
    var skippedProjects: [String] = []
    var skippedLibraries: [String] = []
    var entries = 0
    var truncated = false
}

/// The synchronous walk behind the file rules.
enum UserFilesWalker {
    static let folders = ["Downloads", "Movies", "Desktop", "Documents"]
    static let maxDepth = 24
    static let maxEntries = 400_000
    /// Folders inside the scanned ones that belong to an app (the TV app's managed media).
    static let skippedSubfolders: Set<String> = ["Movies/TV"]

    static func scan(home: URL, settings: Settings) -> UserFilesScan {
        var out = UserFilesScan()
        let keep = min(settings.largeFileThresholdBytes, max(1, settings.oldFileMinimumBytes))
        let projectRoots = Set(settings.expandedProjectRoots(home: home).map { clean($0.standardizedFileURL.path) })
        let homePath = clean(home.path)
        for folder in folders {
            let root = clean(home.appending(path: folder).path)
            var st = stat()
            guard lstat(root, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard let d = opendir(root) else {
                if errno == EPERM || errno == EACCES { out.denied.append("~/" + folder) }
                continue
            }
            closedir(d)
            walk(root: root, folder: folder, dev: st.st_dev, keep: keep, projectRoots: projectRoots,
                 homePath: homePath, into: &out)
        }
        // Dates only for what was kept (Spotlight lookups are per file).
        for i in out.candidates.indices {
            let url = out.candidates[i].url
            var newest = out.candidates[i].modified
            if let added = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate {
                newest = max(newest, added)
            }
            if let used = spotlightLastUsed(url.path) { newest = max(newest, used) }
            out.candidates[i].lastUsed = newest
        }
        return out
    }

    private static func walk(root: String, folder: String, dev: dev_t, keep: Int64, projectRoots: Set<String>,
                             homePath: String, into out: inout UserFilesScan) {
        var stack: [(String, Int, String?)] = [(root, 0, nil)]
        while let (dir, depth, inherited) = stack.popLast() {
            let names = DiskSizer.listDirectory(dir)
            let nameSet = Set(names)
            let rel = dir == root ? folder : folder + "/" + String(dir.dropFirst(root.count + 1))
            if projectRoots.contains(dir) || UserFilesPolicy.isProject(names: nameSet) {
                out.skippedProjects.append("~/" + rel)
                continue
            }
            let mediaProject = inherited ?? names.lazy.compactMap {
                UserFilesPolicy.mediaProjectExtensions[($0 as NSString).pathExtension.lowercased()]
            }.first
            for name in names {
                if out.entries >= maxEntries { out.truncated = true; return }
                out.entries += 1
                if name.hasPrefix(".") || FS.ignoredNames.contains(name) { continue }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, st.st_dev == dev else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                let type = st.st_mode & S_IFMT
                if type == S_IFDIR {
                    let childRel = rel + "/" + name
                    if skippedSubfolders.contains(childRel) || Walk.neverDescend.contains(name)
                        || UserFilesPolicy.editorCacheFolders.contains(name) || name.hasSuffix(".PRV") { continue }
                    if UserFilesPolicy.managedLibraryExtensions.contains(ext) {
                        out.skippedLibraries.append("~/" + childRel)
                        continue
                    }
                    if UserFilesPolicy.projectPackageExtensions.contains(ext) { continue }
                    if UserFilesPolicy.isPackage(name: name, path: path) {
                        let isInstaller = folder == "Downloads" && UserFilesPolicy.installerExtensions.contains(ext)
                        guard let size = DiskSizer.sizeSync(of: URL(filePath: path), tracker: InodeTracker()) else { continue }
                        guard size.allocatedBytes >= keep || isInstaller else { continue }
                        let modified = DiskSizer.lastUsed(of: URL(filePath: path)) ?? date(st.st_mtimespec)
                        out.candidates.append(FileCandidate(
                            url: URL(filePath: path, directoryHint: .isDirectory), location: rel,
                            bytes: size.allocatedBytes, packageKind: packageKind(ext), mediaProject: mediaProject,
                            isInstaller: isInstaller, modified: modified, lastUsed: modified))
                        continue
                    }
                    if depth < maxDepth { stack.append((path, depth + 1, mediaProject)) }
                } else if type == S_IFREG {
                    // Dataless (iCloud "optimised") files aren't on this disk; reading them would download them.
                    if st.st_flags & UInt32(SF_DATALESS) != 0 { continue }
                    if UserFilesPolicy.neverListFileExtensions.contains(ext) { continue }
                    let bytes = Int64(st.st_blocks) * 512
                    let isInstaller = folder == "Downloads" && UserFilesPolicy.installerExtensions.contains(ext)
                    guard bytes >= keep || isInstaller else { continue }
                    let modified = date(st.st_mtimespec)
                    out.candidates.append(FileCandidate(
                        url: URL(filePath: path, directoryHint: .notDirectory), location: rel, bytes: bytes,
                        packageKind: nil, mediaProject: mediaProject, isInstaller: isInstaller,
                        modified: modified, lastUsed: modified))
                }
            }
        }
    }

    static func packageKind(_ ext: String) -> String {
        switch ext {
        case "app": "app bundle"
        case "xcarchive": "Xcode archive"
        case "pkg", "mpkg": "installer package"
        case "sparsebundle": "disk image bundle"
        case "utm", "pvm", "vmwarevm": "virtual machine"
        case "pages", "numbers", "key", "rtfd", "scriv", "sketch", "graffle": "document package"
        case "logicx", "band": "music project"
        default: "package (.\(ext))"
        }
    }

    static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
    }

    /// Spotlight's "last opened" date (set when a file is opened through LaunchServices).
    static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Shares one in-flight computation per key between concurrent callers. Nothing is kept once it finishes,
/// so a later call (e.g. the rescan right after a clean) always sees the disk as it is now.
actor InFlight<Value: Sendable> {
    private var tasks: [String: Task<Value, Never>] = [:]

    func value(key: String, _ make: @escaping @Sendable () async -> Value) async -> Value {
        if let running = tasks[key] { return await running.value }
        let task = Task { await make() }
        tasks[key] = task
        let v = await task.value
        tasks[key] = nil
        return v
    }
}

/// Runs blocking file-system work off the cooperative pool.
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: body()) }
    }
}

/// Sets file dates for fixtures and tests (`setattrlist`): modification and "date added".
enum FileTimes {
    static func set(_ url: URL, modified: Date, added: Date? = nil) throws {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        guard let added else { return }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var ts = timespec(tv_sec: Int(added.timeIntervalSince1970), tv_nsec: 0)
        let rc = setattrlist(url.path, &list, &ts, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
        if rc != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
