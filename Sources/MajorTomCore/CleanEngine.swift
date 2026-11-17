import Darwin
import Foundation

public struct CleanRequest: Sendable {
    public var ruleID: String
    /// Item IDs to clean. They are matched against a fresh resolution of the rule; anything else is refused.
    public var itemIDs: [String]

    public init(ruleID: String, itemIDs: [String]) {
        self.ruleID = ruleID
        self.itemIDs = itemIDs
    }
}

/// A rule-level action to run as part of a clean (e.g. `pnpm store prune`).
public struct ActionRequest: Sendable, Hashable {
    public var ruleID: String
    public var actionID: String

    public init(ruleID: String, actionID: String) {
        self.ruleID = ruleID
        self.actionID = actionID
    }
}

/// Progress of a clean, reported after each item or action is handled.
public struct CleanProgress: Sendable {
    public var completed: Int
    public var total: Int
    /// Display name of the item/action just handled.
    public var current: String
    public var outcome: CleanOutcome
}

public struct CleanOutcome: Sendable, Codable {
    public enum Status: Sendable, Codable, Equatable {
        case wouldClean
        case cleaned
        /// Some of it was removed, some couldn't be (see `leftBehind`); the text says what and what to do.
        case partial(String)
        case skipped(String)
        case failed(String)
    }

    public var ruleID: String
    public var itemID: String
    public var displayName: String
    public var path: String?
    public var method: CleanMethod
    public var estimatedBytes: Int64?
    public var status: Status
    /// Entries a delete couldn't remove (partial or failed deletes), each with advice.
    public var leftBehind: [LeftBehind] = []
    /// All entries left behind (`leftBehind` is capped) and their allocated bytes.
    public var leftBehindCount = 0
    public var leftBehindBytes: Int64 = 0
    /// The raw error(s) behind a failure or partial result, for History.
    public var underlyingError: String?

    /// Allocated bytes the delete actually removed (nil when part of it went to the Trash instead).
    public var removedBytes: Int64?

    /// Scan estimate minus what was left behind, for partial outcomes; never more than was actually removed
    /// (a folder that couldn't be opened counts 0 bytes left behind).
    var removedEstimate: Int64 {
        min(max(0, (estimatedBytes ?? 0) - leftBehindBytes), removedBytes ?? .max)
    }
}

public struct CleanReport: Sendable, Codable {
    public var dryRun: Bool
    public var outcomes: [CleanOutcome]
    /// Sum of scan estimates for items that were (or would be) cleaned.
    public var estimatedBytes: Int64
    /// Measured change in free space; nil for dry runs.
    public var reclaimedBytes: Int64?
}

/// Executes cleans. Everything defaults to a dry run; a real clean needs `execute: true`.
public struct CleanEngine: Sendable {
    public var rules: [Rule]
    public var context: RuleContext
    public var history: HistoryLog
    public var validator: PathValidator
    /// Free-space probe (injectable for tests).
    public var freeSpace: @Sendable () -> Int64
    /// Runs the read-only git queries behind project hibernation rules.
    public var git: any CommandRunner
    /// Performs the actual delete / move-to-Trash (fixture mode and tests use a folder instead of the real Trash).
    public var remover: any FileRemover

    public init(rules: [Rule] = RuleCatalogue.all,
                context: RuleContext = RuleContext(),
                history: HistoryLog = HistoryLog(),
                freeSpace: (@Sendable () -> Int64)? = nil,
                git: any CommandRunner = ProcessRunner(),
                remover: any FileRemover = SystemFileRemover()) {
        self.git = git
        self.remover = remover
        self.rules = rules
        self.context = context
        self.history = history
        self.validator = PathValidator(context: context)
        let home = context.home
        self.freeSpace = freeSpace ?? { VolumeInfo.availableBytes(at: home) ?? 0 }
    }

    /// Cleans items and runs rule-level actions (actions first). `sizes` lets the caller pass scan estimates
    /// (by item ID) for reporting. One measured report and one history entry cover the whole batch.
    public func clean(_ requests: [CleanRequest], actions: [ActionRequest] = [], sizes: [String: Int64] = [:],
                      execute: Bool = false, progress: (@Sendable (CleanProgress) -> Void)? = nil) async -> CleanReport {
        var outcomes: [CleanOutcome] = []
        let before = execute ? freeSpace() : 0
        let total = actions.count + requests.reduce(0) { $0 + $1.itemIDs.count }
        func record(_ o: CleanOutcome) {
            outcomes.append(o)
            progress?(CleanProgress(completed: outcomes.count, total: total, current: o.displayName, outcome: o))
        }

        for request in actions {
            record(await actionOutcome(ruleID: request.ruleID, actionID: request.actionID, execute: execute))
        }

        for request in requests {
            guard let rule = rule(id: request.ruleID) else {
                for id in request.itemIDs {
                    record(CleanOutcome(ruleID: request.ruleID, itemID: id, displayName: id, path: nil, method: .reportOnly,
                                        estimatedBytes: nil, status: .skipped("unknown rule")))
                }
                continue
            }
            // Only paths produced by the rule's own resolver, resolved right now.
            let fresh = await rule.resolveItems(context).items
            let bases = rule.baseDirectories(context)
            for itemID in request.itemIDs {
                guard let item = fresh.first(where: { $0.id == itemID }) else {
                    record(CleanOutcome(ruleID: rule.id, itemID: itemID, displayName: itemID, path: nil,
                                        method: .reportOnly, estimatedBytes: sizes[itemID],
                                        status: .skipped("not produced by the rule's resolver (gone, or never matched)")))
                    continue
                }
                let method = rule.method(for: item)
                var outcome = CleanOutcome(ruleID: rule.id, itemID: item.id, displayName: item.displayName,
                                           path: item.path?.path, method: method,
                                           estimatedBytes: sizes[itemID] ?? item.size, status: .wouldClean)
                await perform(item: item, method: method, bases: bases, trashOnly: rule.isTrashOnly,
                              execute: execute, into: &outcome)
                record(outcome)
            }
        }
        let ruleIDs = requests.map(\.ruleID) + actions.map(\.ruleID)
        return await finish(outcomes: outcomes, ruleIDs: ruleIDs, before: before, execute: execute)
    }

    /// A catalogue rule, or the per-project hibernation rule for `hibernate:<path>` IDs.
    public func rule(id: String) -> Rule? {
        if let r = rules.first(where: { $0.id == id }) { return r }
        if let path = ProjectHibernation.projectPath(ruleID: id) { return ProjectHibernation.rule(path: path, git: git) }
        return nil
    }

    /// Runs a rule-level action (e.g. `pnpm store prune`). Dry run unless `execute`.
    public func runAction(ruleID: String, actionID: String, execute: Bool = false) async -> CleanReport {
        await clean([], actions: [ActionRequest(ruleID: ruleID, actionID: actionID)], execute: execute)
    }

    private func actionOutcome(ruleID: String, actionID: String, execute: Bool) async -> CleanOutcome {
        var outcome = CleanOutcome(ruleID: ruleID, itemID: "action:" + actionID, displayName: actionID, path: nil,
                                   method: .reportOnly, estimatedBytes: nil, status: .skipped("unknown action"))
        guard let rule = rule(id: ruleID) else {
            outcome.status = .skipped("unknown rule")
            return outcome
        }
        let fresh = await rule.resolveItems(context).items
        guard let action = rule.actions(context, fresh).first(where: { $0.id == actionID }) else { return outcome }
        outcome.displayName = action.title
        outcome.method = .command(action.command)
        if !action.runnable {
            outcome.status = .skipped("run it yourself: \(action.commandLine)")
        } else if !execute {
            outcome.status = .wouldClean
        } else {
            outcome.status = await runCommand(action.command)
        }
        return outcome
    }

    private func finish(outcomes: [CleanOutcome], ruleIDs: [String], before: Int64, execute: Bool) async -> CleanReport {
        let estimate = outcomes.reduce(Int64(0)) { sum, o in
            switch o.status {
            case .wouldClean where !execute, .cleaned where execute: sum + (o.estimatedBytes ?? 0)
            case .partial where execute: sum + o.removedEstimate
            default: sum
            }
        }
        guard execute else {
            return CleanReport(dryRun: true, outcomes: outcomes, estimatedBytes: estimate, reclaimedBytes: nil)
        }
        let reclaimed = freeSpace() - before
        let attempted = outcomes.filter { if case .skipped = $0.status { false } else { true } }
        if !attempted.isEmpty {
            let entry = HistoryEntry(
                id: UUID(), date: Date(), ruleIDs: Array(Set(ruleIDs)).sorted(),
                items: attempted.map {
                    var error: String?
                    var partial: Bool?
                    switch $0.status {
                    case .failed(let e): error = e
                    case .partial(let e): error = e; partial = true
                    default: break
                    }
                    return HistoryEntry.ItemRecord(ruleID: $0.ruleID, itemID: $0.itemID, displayName: $0.displayName,
                                                   path: $0.path, method: $0.method.summary,
                                                   estimatedBytes: $0.estimatedBytes, succeeded: $0.status == .cleaned,
                                                   error: error, partial: partial,
                                                   leftBehind: $0.leftBehind.isEmpty ? nil : $0.leftBehind,
                                                   underlyingError: $0.underlyingError)
                },
                estimatedBytes: estimate, reclaimedBytes: reclaimed)
            try? history.append(entry)
        }
        return CleanReport(dryRun: false, outcomes: outcomes, estimatedBytes: estimate, reclaimedBytes: reclaimed)
    }

    private func perform(item: Item, method: CleanMethod, bases: [URL], trashOnly: Bool, execute: Bool,
                         into outcome: inout CleanOutcome) async {
        if item.isProtected { outcome.status = .skipped("protected: \(item.note ?? "never offered")"); return }
        if trashOnly, method != .trash {
            outcome.status = .skipped("refused: this rule only ever moves items to the Trash (got \(method.summary))")
            return
        }
        switch method {
        case .reportOnly:
            outcome.status = .skipped("report only")
        case .command(let argv):
            outcome.status = execute ? await runCommand(argv) : .wouldClean
        case .delete, .deleteContents, .trash:
            guard let path = item.path else { outcome.status = .skipped("no path"); return }
            let paths = [path] + item.companionPaths
            do {
                for p in paths {
                    try validator.validate(p, bases: bases)
                    if trashOnly { try validator.validateUserFile(p, bases: bases) }
                }
            } catch {
                outcome.status = .skipped("refused: \(error.description)")
                return
            }
            guard execute else { outcome.status = .wouldClean; return }
            var removal = TreeRemoval()
            var trashedAny = false
            for p in paths {
                do {
                    // Re-validate right before touching each path.
                    try validator.validate(p, bases: bases)
                    if trashOnly || method == .trash {
                        if trashOnly { try validator.validateUserFile(p, bases: bases) }
                        try remover.trash(p)
                        removal.removedEntries += 1
                        trashedAny = true
                    } else {
                        // Entry by entry, never following symlinks; carries on past what it can't remove.
                        let r = remover.delete(p, keepingFolder: method == .deleteContents && p == path)
                        removal.removedEntries += r.removedEntries
                        removal.removedBytes += r.removedBytes
                        removal.leftCount += r.leftCount
                        removal.leftBytes += r.leftBytes
                        removal.leftBehind += r.leftBehind
                    }
                } catch let e as PathValidationError {
                    // Nothing removed yet for this path; refuse it (earlier paths of the item may be gone).
                    if removal.removedEntries == 0 && removal.leftCount == 0 {
                        outcome.status = .skipped("refused: \(e.description)")
                        return
                    }
                    removal.leftCount += 1
                    removal.leftBehind.append(LeftBehind(path: p.path, errno: 0, advice: "refused: \(e.description)",
                                                         underlying: "path validation"))
                } catch {
                    let (advice, underlying) = RemovalAdvice.advice(for: error, path: p.path)
                    removal.leftCount += 1
                    removal.leftBehind.append(LeftBehind(path: p.path, errno: 0, advice: advice, underlying: underlying))
                }
            }
            outcome.leftBehind = removal.leftBehind
            outcome.leftBehindCount = removal.leftCount
            outcome.leftBehindBytes = removal.leftBytes
            outcome.removedBytes = trashedAny ? nil : removal.removedBytes
            outcome.status = Self.status(for: removal, itemPath: path)
            if !removal.isComplete {
                outcome.underlyingError = removal.leftBehind
                    .map { "\(displayPath($0.path)): \($0.underlying)" }.joined(separator: "; ")
            }
        }
    }

    private func displayPath(_ p: String) -> String {
        let h = context.home.standardizedFileURL.path(percentEncoded: false).replacing(/\/+$/, with: "")
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }

    /// `.cleaned`, `.partial` (something removed, something left) or `.failed` (nothing removed).
    static func status(for removal: TreeRemoval, itemPath: URL) -> CleanOutcome.Status {
        guard !removal.isComplete else { return .cleaned }
        let first = removal.leftBehind.first
        // Group by advice so one cause shows once, with the entries it affects.
        var advices: [String] = []
        for l in removal.leftBehind where !advices.contains(l.advice) { advices.append(l.advice) }
        let base = itemPath.path(percentEncoded: false)
        func rel(_ p: String) -> String {
            p == base ? itemPath.lastPathComponent : (p.hasPrefix(base + "/") ? String(p.dropFirst(base.count + 1)) : p)
        }
        let what = removal.leftCount == 1
            ? "“\(rel(first?.path ?? base))”"
            : "\(removal.leftCount) entries (e.g. “\(rel(first?.path ?? base))”)"
        let reasons = advices.prefix(3).joined(separator: "; ")
        if removal.removedEntries == 0 {
            return .failed("couldn't remove \(what): \(reasons)")
        }
        let freed = removal.removedBytes > 0 ? ", about \(ByteFormat.string(removal.removedBytes)) freed" : ""
        return .partial("removed \(removal.removedEntries) entr\(removal.removedEntries == 1 ? "y" : "ies")\(freed); left \(what): \(reasons)")
    }

    private func runCommand(_ argv: [String]) async -> CleanOutcome.Status {
        guard let result = await context.runner.run(argv, timeout: 600) else {
            return .failed("\(argv.first ?? "") not found")
        }
        if result.succeeded { return .cleaned }
        let msg = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(result.timedOut ? "timed out" : (msg.isEmpty ? "exit \(result.exitCode)" : msg))
    }
}

extension CleanOutcome.Status: Hashable {}

/// The only two ways the engine removes a path.
public protocol FileRemover: Sendable {
    /// Deletes `url` entry by entry without following symlinks (`TreeRemover`), carrying on past anything it
    /// can't remove; `keepingFolder` empties a folder and leaves it in place.
    func delete(_ url: URL, keepingFolder: Bool) -> TreeRemoval
    func trash(_ url: URL) throws
}

extension FileRemover {
    public func delete(_ url: URL, keepingFolder: Bool) -> TreeRemoval {
        TreeRemover.remove(url, keepingFolder: keepingFolder)
    }
}

/// The real thing: `TreeRemover` / Finder's Trash.
public struct SystemFileRemover: FileRemover {
    public init() {}
    public func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
}

/// "Trash" = move into a given folder. Fixture mode and tests use it so they never fill the user's real Trash.
public struct FolderTrashRemover: FileRemover {
    public let trashFolder: URL
    public init(trashFolder: URL) { self.trashFolder = trashFolder }

    public func trash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        var dest = trashFolder.appending(path: url.lastPathComponent)
        var n = 2
        while FS.exists(dest) {
            dest = trashFolder.appending(path: "\(url.deletingPathExtension().lastPathComponent) \(n)"
                + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"))
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: dest)
    }
}

public enum VolumeInfo {
    /// Free bytes on the volume containing `url` (statfs; excludes purgeable space so before/after is honest).
    public static func availableBytes(at url: URL) -> Int64? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    public static func totalBytes(at url: URL) -> Int64? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        return Int64(fs.f_blocks) * Int64(fs.f_bsize)
    }
}
