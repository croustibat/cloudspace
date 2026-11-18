import Darwin
import Foundation

/// Something a delete had to leave behind, with what the user can do about it.
public struct LeftBehind: Codable, Sendable, Hashable {
    /// Absolute path of the entry that couldn't be removed.
    public var path: String
    public var errno: Int32
    /// Actionable, user-facing ("in use by the iOS Simulator — quit Simulator and try again").
    public var advice: String
    /// The raw failure, e.g. "rmdir: Directory not empty (errno 66)". Recorded in History.
    public var underlying: String

    public init(path: String, errno: Int32, advice: String, underlying: String) {
        self.path = path
        self.errno = errno
        self.advice = advice
        self.underlying = underlying
    }
}

/// What a `TreeRemover` run did.
public struct TreeRemoval: Sendable {
    /// Files, links and folders removed.
    public var removedEntries = 0
    /// Allocated bytes of the files removed (informative only; reclaimed space is measured from free space).
    public var removedBytes: Int64 = 0
    /// Entries left behind, deepest cause only (a folder kept because a child failed isn't listed again).
    /// Capped at `TreeRemover.maxReported`; `leftCount` is the full count.
    public var leftBehind: [LeftBehind] = []
    public var leftCount = 0
    /// Allocated bytes of the files left behind (folders that couldn't be read count as 0).
    public var leftBytes: Int64 = 0
    /// The item itself is gone (always false when the folder was deliberately kept).
    public var rootRemoved = false

    public var isComplete: Bool { leftCount == 0 }
}

/// Removes a file, link or folder entry by entry, carrying on past anything it can't remove.
///
/// - Never follows symlinks: every folder is opened relative to its parent with `O_NOFOLLOW`, entries are
///   examined with `fstatat(AT_SYMLINK_NOFOLLOW)` and removed with `unlinkat`, so a link (even one swapped in
///   mid-walk) is removed as a link and its target is never touched.
/// - Never crosses into another volume mounted inside the tree.
/// - A folder that a running process refills while it is being emptied (e.g. a booted simulator's log
///   folder) is emptied again, twice, before it is reported.
/// - `keepingFolder` removes the folder's contents and leaves the (now empty) folder itself, for app-owned
///   folders such as `~/Library/Logs/<App>` that the app expects to exist.
public enum TreeRemover {
    public static let maxReported = 25
    static let refillRetries = 2
    public static let maxDepth = 1000

    /// Stack for the walk: recursion costs a few KB per level, far more than a 512 KB cooperative-pool thread
    /// allows at `maxDepth` (it crashed at ~150 levels there).
    static let stackSize = 64 << 20

    public static func remove(_ url: URL, keepingFolder: Bool = false) -> TreeRemoval {
        final class Box: @unchecked Sendable {
            var result = TreeRemoval()
            let done = DispatchSemaphore(value: 0)
        }
        let box = Box()
        let thread = Thread {
            box.result = removeOnThisThread(url, keepingFolder: keepingFolder)
            box.done.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        box.done.wait()
        return box.result
    }

    private static func removeOnThisThread(_ url: URL, keepingFolder: Bool) -> TreeRemoval {
        var r = TreeRemoval()
        let path = clean(url.path(percentEncoded: false))
        // Callers validate first; refuse anything a relative or dotted path could redirect (e.g. `a/..`).
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), !comps.isEmpty, !comps.contains(where: { $0 == "." || $0 == ".." }) else {
            record(&r, path, EINVAL, op: "refused path", size: 0)
            return r
        }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let e = errno
            if e == ENOENT { r.rootRemoved = !keepingFolder } else { record(&r, path, e, op: "lstat", size: 0) }
            return r
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            // A file or a symlink: remove the entry itself (keepingFolder only applies to folders).
            if unlink(path) == 0 || errno == ENOENT {
                r.removedEntries += 1
                r.removedBytes += allocated(st)
                r.rootRemoved = true
            } else {
                record(&r, path, errno, op: "unlink", size: allocated(st))
            }
            return r
        }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let pfd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard pfd >= 0 else {
            record(&r, path, errno, op: "open parent", size: 0)
            return r
        }
        defer { close(pfd) }
        // The item itself is a mount point: never empty another volume.
        var pst = stat()
        guard fstat(pfd, &pst) == 0, pst.st_dev == st.st_dev else {
            record(&r, path, EXDEV, op: "mount point", size: 0)
            return r
        }
        let removed = removeDirectory(parentFD: pfd, name: Array(name.utf8CString), path: path, device: st.st_dev,
                                      depth: 0, removeSelf: !keepingFolder, into: &r)
        r.rootRemoved = removed && !keepingFolder
        return r
    }

    /// Empties the folder `name` (relative to `parentFD`) and, if `removeSelf`, removes it. True when nothing
    /// was left behind.
    private static func removeDirectory(parentFD: Int32, name: [CChar], path: String, device: dev_t, depth: Int,
                                        removeSelf: Bool, into r: inout TreeRemoval) -> Bool {
        for attempt in 0...refillRetries {
            guard clearContents(parentFD: parentFD, name: name, path: path, device: device, depth: depth, into: &r)
            else { return false }
            guard removeSelf else { return true }
            if unlinkat(parentFD, name, AT_REMOVEDIR) == 0 {
                r.removedEntries += 1
                return true
            }
            let e = errno
            if e == ENOENT { return true }
            // Refilled by a running process between emptying and rmdir: empty it again.
            if e == ENOTEMPTY && attempt < refillRetries { continue }
            record(&r, path, e, op: "rmdir", size: 0)
            return false
        }
        return false
    }

    /// Removes everything inside the folder. True when nothing was left behind.
    private static func clearContents(parentFD: Int32, name: [CChar], path: String, device: dev_t, depth: Int,
                                      into r: inout TreeRemoval) -> Bool {
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            if e == ENOENT { return true }
            record(&r, path, e, op: "open", size: 0)
            return false
        }
        guard let dir = fdopendir(fd) else {
            let e = errno
            close(fd)
            record(&r, path, e, op: "opendir", size: 0)
            return false
        }
        defer { closedir(dir) }
        let dfd = dirfd(dir)

        // Raw names (byte-exact, whatever their encoding); "." and ".." skipped.
        var names: [[CChar]] = []
        while let ent = readdir(dir) {
            let n = withUnsafeBytes(of: ent.pointee.d_name) { raw -> [CChar] in
                let bytes = raw.bindMemory(to: CChar.self)
                let len = min(Int(ent.pointee.d_namlen), bytes.count)
                return Array(bytes[0..<len]) + [0]
            }
            if n == [46, 0] || n == [46, 46, 0] { continue }
            names.append(n)
        }

        var ok = true
        for n in names {
            let display = path + "/" + String(decoding: n.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
            var st = stat()
            guard fstatat(dfd, n, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                let e = errno
                if e != ENOENT { record(&r, display, e, op: "stat", size: 0); ok = false }
                continue
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if st.st_dev != device {
                    record(&r, display, EXDEV, op: "mount point", size: 0)
                    ok = false
                    continue
                }
                if depth + 1 > maxDepth {
                    record(&r, display, ENAMETOOLONG, op: "nested deeper than \(maxDepth) folders", size: 0)
                    ok = false
                    continue
                }
                if !removeDirectory(parentFD: dfd, name: n, path: display, device: device, depth: depth + 1,
                                    removeSelf: true, into: &r) {
                    ok = false
                }
            } else if unlinkat(dfd, n, 0) == 0 {
                r.removedEntries += 1
                r.removedBytes += allocated(st)
            } else {
                let e = errno
                if e != ENOENT {
                    record(&r, display, e, op: "unlink", size: allocated(st))
                    ok = false
                }
            }
        }
        return ok
    }

    private static func allocated(_ st: stat) -> Int64 { Int64(st.st_blocks) * 512 }

    private static func record(_ r: inout TreeRemoval, _ path: String, _ e: Int32, op: String, size: Int64) {
        r.leftCount += 1
        r.leftBytes += size
        guard r.leftBehind.count < maxReported else { return }
        r.leftBehind.append(LeftBehind(path: path, errno: e, advice: RemovalAdvice.advice(path: path, errno: e),
                                       underlying: RemovalAdvice.underlying(op: op, errno: e)))
    }
}

/// Turns a failed removal (path + errno) into something the user can act on.
public enum RemovalAdvice {
    public static func underlying(op: String, errno e: Int32) -> String {
        "\(op): \(String(cString: strerror(e))) (errno \(e))"
    }

    public static func advice(path: String, errno e: Int32) -> String {
        let q = shellQuote(path)
        switch e {
        case ENOTEMPTY:
            let holders = openers(under: path)
            if isSimulator(path: path, holders: holders) {
                return "kept being refilled by the running iOS Simulator — quit Simulator (or run `xcrun simctl shutdown all`) and try again"
            }
            if !holders.isEmpty {
                return "kept being refilled by \(holders.map(\.name).joined(separator: ", ")), which is running — quit it and try again"
            }
            return "kept being refilled while it was being deleted — quit the app that writes here and try again"
        case EBUSY, ETXTBSY:
            let holders = openers(under: path)
            if isSimulator(path: path, holders: holders) {
                return "in use by the iOS Simulator — quit Simulator (or run `xcrun simctl shutdown all`) and try again"
            }
            let who = holders.isEmpty ? "" : " by \(holders.map(\.name).joined(separator: ", "))"
            return "in use\(who) — quit it and try again"
        case EXDEV:
            return "a volume is mounted here — eject it first; CloudSpace doesn't delete across volumes"
        case EROFS:
            return "on a read-only volume — can't be removed from here"
        case ENAMETOOLONG:
            return "nested too deeply (over \(TreeRemover.maxDepth) folders inside each other) — CloudSpace stops there; remove it yourself with `rm -rf \(q)`"
        case EINVAL:
            return "refused: not a plain absolute path"
        case EPERM, EACCES:
            return permissionAdvice(path: path, quoted: q)
        default:
            return String(cString: strerror(e))
        }
    }

    private static func permissionAdvice(path: String, quoted q: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        var st = stat()
        var pst = stat()
        let haveSelf = lstat(path, &st) == 0
        let haveParent = lstat(parent, &pst) == 0
        let uid = getuid()
        if haveSelf {
            if st.st_flags & UInt32(SF_RESTRICTED) != 0 {
                return "protected by System Integrity Protection — macOS doesn't allow removing it; leave it"
            }
            if st.st_flags & UInt32(SF_IMMUTABLE | SF_APPEND) != 0 {
                return "locked by the system (schg flag) — CloudSpace never uses admin rights; to remove it yourself run `sudo chflags -R noschg \(q) && sudo rm -rf \(q)`"
            }
            if st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
                return "locked (Finder's Locked / uchg flag) — unlock it with `chflags -R nouchg \(q)` and try again"
            }
            if st.st_uid != uid {
                return "owned by \(userName(st.st_uid)) — CloudSpace never uses admin rights; remove it yourself with `sudo rm -rf \(q)`"
            }
        }
        if haveParent {
            let qp = shellQuote(parent)
            if pst.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
                return "its folder is locked (uchg flag) — unlock it with `chflags nouchg \(qp)` and try again"
            }
            if pst.st_uid != uid {
                return "its folder is owned by \(userName(pst.st_uid)) — CloudSpace never uses admin rights; remove it yourself with `sudo rm -rf \(q)`"
            }
            if access(parent, W_OK) != 0 {
                return "its folder is read-only — run `chmod u+w \(qp)` and try again"
            }
        }
        if haveSelf, (st.st_mode & S_IFMT) == S_IFDIR, access(path, R_OK | W_OK | X_OK) != 0 {
            return "this folder isn't readable/writable — run `chmod -R u+rwx \(q)` and try again"
        }
        if haveSelf, hasACL(path) {
            return "an access-control list on it forbids deleting it (see `ls -led \(q)`)"
        }
        return "macOS blocked access (privacy protection) — give CloudSpace Full Disk Access in System Settings › Privacy & Security › Full Disk Access, then try again"
    }

    /// Advice for an error thrown by Foundation (e.g. a move to the Trash), from its POSIX cause when it has one.
    public static func advice(for error: any Error, path: String) -> (advice: String, underlying: String) {
        let ns = error as NSError
        let underlyingText = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        var posix: Int32?
        if ns.domain == NSPOSIXErrorDomain { posix = Int32(ns.code) }
        if posix == nil, let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
            posix = Int32(u.code)
        }
        guard let e = posix else { return (ns.localizedDescription, underlyingText) }
        return (advice(path: path, errno: e), underlyingText + " (errno \(e))")
    }

    // MARK: helpers

    struct Holder: Hashable {
        var pid: pid_t
        var name: String
        var executable: String
    }

    private static func isSimulator(path: String, holders: [Holder]) -> Bool {
        path.contains("/Library/Logs/CoreSimulator/") || path.hasSuffix("/Library/Logs/CoreSimulator")
            || path.contains("/Library/Developer/CoreSimulator/")
            || holders.contains { $0.executable.contains("/CoreSimulator/") || $0.name == "Simulator" || $0.name == "launchd_sim" }
    }

    /// Processes holding files open inside `path` (a bounded look at its current contents).
    static func openers(under path: String, limit: Int = 64) -> [Holder] {
        var files: [String] = [path]
        if let walker = FileManager.default.enumerator(atPath: path) {
            while files.count < limit, let rel = walker.nextObject() as? String { files.append(path + "/" + rel) }
        }
        var seen = Set<pid_t>()
        var out: [Holder] = []
        for f in files {
            let size = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, f, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY), nil, 0)
            guard size > 0 else { continue }
            var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 16)
            let got = pids.withUnsafeMutableBytes {
                proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, f, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                                  $0.baseAddress, Int32($0.count))
            }
            guard got > 0 else { continue }
            for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 && seen.insert(pid).inserted {
                var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let n = proc_pidpath(pid, &buf, UInt32(buf.count))
                let exe = n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
                let name = exe.isEmpty ? "process \(pid)" : (exe as NSString).lastPathComponent
                out.append(Holder(pid: pid, name: name, executable: exe))
            }
        }
        return out
    }

    private static func userName(_ uid: uid_t) -> String {
        if uid == 0 { return "root" }
        if let pw = getpwuid(uid) { return String(cString: pw.pointee.pw_name) }
        return "user \(uid)"
    }

    private static func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }
}
