import Foundation
import MajorTomCore
import Observation

public enum ScanState: Sendable, Equatable {
    case idle
    case scanning(completed: Int, total: Int)
    case done(at: Date, duration: TimeInterval)
}

public enum CheckState: Sendable, Equatable { case none, some, all }

/// App state for the main window. Views stay thin: selection, totals, plans and the clean flow live here.
@MainActor
@Observable
public final class GroundControlModel {
    public let environment: AppEnvironment
    @ObservationIgnored private let scanner: MajorTomCore.Scanner
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    public private(set) var settings: Settings
    public private(set) var results: [String: RuleResult] = [:]
    public private(set) var scanState: ScanState = .idle
    public private(set) var scanningRuleIDs: Set<String> = []
    public private(set) var disk: DiskStatus
    public private(set) var fullDiskAccess: FullDiskAccess.Status
    /// Newest first.
    public private(set) var history: [HistoryEntry] = []
    public var checkedItems: Set<ItemKey> = []
    public var checkedActions: Set<ActionRequest> = []
    /// Drives the clean sheet.
    public var cleanSession: CleanSession?
    public internal(set) var settingsError: String?
    /// When the last complete scan of every enabled rule finished (drives the weekly background rescan).
    public internal(set) var lastFullScan: Date?
    /// A Quick clean asked for (menu bar / notification) while no scan results were available yet.
    public private(set) var pendingQuickClean = false

    // Projects (M3). Logic lives in GroundControlModel+Projects.swift.
    public internal(set) var projects: [Project] = []
    public internal(set) var projectScanState: ScanState = .idle
    /// False until the strippable directories of the current `projects` have been measured.
    public internal(set) var projectsSized = false
    /// Paths of projects selected for hibernation.
    public var checkedProjects: Set<String> = []
    /// Newest hibernation record per project path.
    public internal(set) var hibernations: [String: HibernationRecord] = [:]
    @ObservationIgnored var projectScanTask: Task<Void, Never>?

    // NAS offload (M6). Logic lives in GroundControlModel+Offload.swift.
    public internal(set) var offloadCandidates: [OffloadCandidate] = []
    public internal(set) var offloadCandidatesState: ScanState = .idle
    /// Newest first.
    public internal(set) var offloadRecords: [OffloadRecord] = []
    public internal(set) var destinationCheck: DestinationCheck = .missing("")
    /// Offloads whose payload is on the share right now (only known while it's mounted).
    public internal(set) var reachableOffloads: Set<UUID> = []
    /// `.partial` folders left on the share by an interrupted offload.
    public internal(set) var incompleteCopies: [URL] = []
    /// Candidate IDs (paths) selected for offloading.
    public var checkedOffloads: Set<String> = []
    public internal(set) var offloadSession: OffloadSession?
    public internal(set) var restoreSession: RestoreSession?
    public internal(set) var offloadMessage: String?
    /// iCloud Drive destination only: which offloaded archives still take space here, and whether they're uploaded.
    public internal(set) var evictionPreview: EvictionReport?
    @ObservationIgnored var offloadTask: Task<Void, Never>?
    /// Polls iCloud upload state after an offload so local copies are freed as soon as they may be.
    @ObservationIgnored var evictionWatchTask: Task<Void, Never>?
    /// Seconds between polls while an archive is still uploading (tests shorten it).
    @ObservationIgnored var evictionWatchInterval: Duration = .seconds(30)

    public init(environment: AppEnvironment) {
        self.environment = environment
        let settings = environment.settingsStore.load()
        var context = environment.context
        context.settings = settings
        self.scanner = MajorTomCore.Scanner(rules: environment.rules, context: context)
        self.settings = settings
        self.disk = DiskStatus.measure(environment.volumeURL)
        self.fullDiskAccess = environment.fullDiskAccess()
        reloadHistory()
        reloadHibernations()
        reloadOffloadRecords()
    }

    // MARK: Rules and totals

    /// Enabled rules in catalogue order.
    public var rules: [Rule] { environment.rules.filter { !settings.disabledRuleIDs.contains($0.id) } }

    public func rule(id: String) -> Rule? { environment.rules.first { $0.id == id } }

    /// Categories that have at least one enabled rule, in catalogue order.
    public var categories: [RuleCategory] {
        let present = Set(rules.map(\.category))
        return RuleCategory.allCases.filter(present.contains)
    }

    /// Rules in a category (all enabled rules for nil), biggest reclaimable first; unscanned keep catalogue order.
    public func rules(in category: RuleCategory?) -> [Rule] {
        let list = rules.filter { category == nil || $0.category == category }
        return list.enumerated().sorted { a, b in
            let sa = reclaimable(ruleID: a.element.id), sb = reclaimable(ruleID: b.element.id)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    /// Items to show for a rule: everything the scan found except paths the user chose to ignore.
    public func items(ruleID: String) -> [Item] {
        guard let r = results[ruleID] else { return [] }
        let ignored = Set(settings.ignoredPaths)
        return r.items.filter { item in item.path.map { !ignored.contains($0.path) } ?? true }
    }

    public func actions(ruleID: String) -> [RuleAction] { results[ruleID]?.actions ?? [] }

    public func reclaimable(ruleID: String) -> Int64 {
        items(ruleID: ruleID).filter(\.isCleanable).reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// Everything found, including report-only and protected items.
    public func totalFound(ruleID: String) -> Int64 {
        items(ruleID: ruleID).reduce(0) { $0 + ($1.size ?? 0) }
    }

    public func reclaimable(category: RuleCategory?) -> Int64 {
        rules.filter { category == nil || $0.category == category }.reduce(0) { $0 + reclaimable(ruleID: $1.id) }
    }

    public var reclaimableByTier: [Tier: Int64] {
        rules.reduce(into: [:]) { $0[$1.tier, default: 0] += reclaimable(ruleID: $1.id) }
    }

    public var totalReclaimable: Int64 { reclaimableByTier.values.reduce(0, +) }

    public var hasScanned: Bool { !results.isEmpty }
    public var isScanning: Bool { if case .scanning = scanState { true } else { false } }

    // MARK: Selection

    public func isChecked(ruleID: String, itemID: String) -> Bool {
        checkedItems.contains(ItemKey(ruleID: ruleID, itemID: itemID))
    }

    public func setChecked(_ on: Bool, ruleID: String, itemID: String) {
        let key = ItemKey(ruleID: ruleID, itemID: itemID)
        guard on else { checkedItems.remove(key); return }
        guard let item = items(ruleID: ruleID).first(where: { $0.id == itemID }), item.isCleanable else { return }
        checkedItems.insert(key)
    }

    public func toggle(ruleID: String, itemIDs: some Sequence<String>) {
        let ids = Array(itemIDs)
        let allOn = ids.allSatisfy { isChecked(ruleID: ruleID, itemID: $0) }
        for id in ids { setChecked(!allOn, ruleID: ruleID, itemID: id) }
    }

    public func checkState(ruleID: String) -> CheckState {
        let cleanable = items(ruleID: ruleID).filter(\.isCleanable)
        let n = cleanable.filter { isChecked(ruleID: ruleID, itemID: $0.id) }.count
        if n == 0 { return .none }
        return n == cleanable.count ? .all : .some
    }

    public func setAllChecked(_ on: Bool, ruleID: String) {
        for item in items(ruleID: ruleID) where item.isCleanable { setChecked(on, ruleID: ruleID, itemID: item.id) }
    }

    public func isChecked(ruleID: String, actionID: String) -> Bool {
        checkedActions.contains(ActionRequest(ruleID: ruleID, actionID: actionID))
    }

    public func setChecked(_ on: Bool, ruleID: String, actionID: String) {
        let key = ActionRequest(ruleID: ruleID, actionID: actionID)
        guard on else { checkedActions.remove(key); return }
        guard actions(ruleID: ruleID).contains(where: { $0.id == actionID && $0.runnable }) else { return }
        checkedActions.insert(key)
    }

    public func clearSelection() {
        checkedItems.removeAll()
        checkedActions.removeAll()
    }

    /// Replaces the selection with every cleanable item of every enabled `safe` rule.
    public func selectAllSafe() {
        clearSelection()
        for rule in rules where rule.tier == .safe {
            for item in items(ruleID: rule.id) where item.isCleanable {
                checkedItems.insert(ItemKey(ruleID: rule.id, itemID: item.id))
            }
        }
    }

    public var safeReclaimable: Int64 { reclaimableByTier[.safe] ?? 0 }

    // MARK: Plan and clean flow

    /// What would be cleaned with the current selection.
    public var plan: CleanPlan {
        var groups: [CleanPlan.Group] = []
        for rule in environment.rules {
            let items = items(ruleID: rule.id).filter { $0.isCleanable && isChecked(ruleID: rule.id, itemID: $0.id) }
            let actions = actions(ruleID: rule.id).filter { $0.runnable && isChecked(ruleID: rule.id, actionID: $0.id) }
            guard !items.isEmpty || !actions.isEmpty else { continue }
            groups.append(CleanPlan.Group(ruleID: rule.id, title: rule.title, tier: rule.tier, impact: rule.impact,
                                          recovery: rule.recovery, regenCost: rule.regenCost,
                                          items: items, actions: actions))
        }
        return CleanPlan(groups: groups.sorted { $0.tier != $1.tier ? $0.tier < $1.tier : $0.estimatedBytes > $1.estimatedBytes })
    }

    /// "Quick clean": select all safe items and open the review sheet.
    public func quickClean() async {
        selectAllSafe()
        await review()
    }

    /// Quick clean from outside the main window (menu bar, notification action). Same as `quickClean()` —
    /// it only opens the review sheet; nothing is removed until the user confirms there. Without scan
    /// results it scans first (or waits for the running scan). Never includes project hibernation.
    public func requestQuickClean() async {
        guard cleanSession == nil else { return }
        if isScanning {
            pendingQuickClean = true
            return
        }
        if !hasScanned { await scanAll() }
        pendingQuickClean = false
        await quickClean()
    }

    /// Opens the review sheet and asks the engine for a dry run of exactly this plan.
    public func review() async {
        await review(plan)
    }

    /// Opens the review sheet for any plan (rule selection or project hibernation) and dry-runs it.
    func review(_ plan: CleanPlan) async {
        guard !plan.isEmpty, cleanSession == nil else { return }
        cleanSession = CleanSession(plan: plan, phase: .reviewing(dryRun: nil))
        let engine = environment.engine(settings: settings)
        let report = await engine.clean(plan.requests, actions: plan.actionRequests, sizes: plan.sizes, execute: false)
        guard case .reviewing = cleanSession?.phase else { return }
        cleanSession?.phase = .reviewing(dryRun: report)
    }

    public func cancelReview() {
        if case .cleaning = cleanSession?.phase { return }
        cleanSession = nil
    }

    /// The user confirmed in the review sheet: run the clean for real, measure, log, rescan what changed.
    public func confirmClean() async {
        guard let session = cleanSession, session.canConfirm else { return }
        let plan = session.plan
        cleanSession?.phase = .cleaning(completed: 0, total: plan.itemCount + plan.actionCount, current: "")
        let engine = environment.engine(settings: settings)
        let (stream, continuation) = AsyncStream<CleanProgress>.makeStream()
        let work = Task.detached {
            let report = await engine.clean(plan.requests, actions: plan.actionRequests, sizes: plan.sizes,
                                            execute: true, progress: { continuation.yield($0) })
            continuation.finish()
            return report
        }
        for await p in stream {
            cleanSession?.phase = .cleaning(completed: p.completed, total: p.total, current: p.current)
        }
        let report = await work.value
        cleanSession?.phase = .finished(report)
        clearSelection()
        reloadHistory()
        refreshDisk()
        if plan.hibernatesProjects {
            recordHibernations(report)
            await scanProjects()
            // "Hibernate first" from the offload list: refresh what offloading those projects would copy.
            if offloadCandidatesState != .idle { await scanOffloadCandidates() }
        }
        await scan(ruleIDs: plan.groups.map(\.ruleID).filter { rule(id: $0) != nil })
    }

    public func dismissResult() {
        if case .cleaning = cleanSession?.phase { return }
        cleanSession = nil
    }

    // MARK: Scanning

    public func scanAll() async {
        let ids = rules.map(\.id)
        await scan(ruleIDs: ids)
        if !Task.isCancelled, ids.allSatisfy({ results[$0] != nil }) { lastFullScan = Date() }
    }

    public func startScanAll() {
        scanTask?.cancel()
        scanTask = Task { await self.scanAll() }
    }

    public func cancelScan() {
        scanTask?.cancel()
    }

    public func scan(ruleIDs: [String]) async {
        guard !ruleIDs.isEmpty else { return }
        let scanner = self.scanner
        let total = ruleIDs.count
        scanningRuleIDs.formUnion(ruleIDs)
        await scanner.update(settings: settings)  // thresholds and project roots as they are now
        scanState = .scanning(completed: 0, total: total)
        let start = Date()
        let (stream, continuation) = AsyncStream<ScanEvent>.makeStream()
        let work = Task {
            let r = await scanner.scan(ruleIDs: ruleIDs, progress: { continuation.yield($0) })
            continuation.finish()
            return r
        }
        await withTaskCancellationHandler {
            var done = 0
            for await event in stream {
                if case .ruleFinished(let result) = event, !Task.isCancelled {
                    done += 1
                    results[result.ruleID] = result
                    scanningRuleIDs.remove(result.ruleID)
                    scanState = .scanning(completed: done, total: total)
                    pruneSelection(ruleID: result.ruleID)
                }
            }
        } onCancel: {
            work.cancel()
        }
        _ = await work.value
        scanningRuleIDs.subtract(ruleIDs)
        scanState = .done(at: Date(), duration: Date().timeIntervalSince(start))
        refreshDisk()
        if pendingQuickClean, !isScanning, scanningRuleIDs.isEmpty {
            pendingQuickClean = false
            await quickClean()
        }
    }

    /// Drops checks for items a rescan no longer reports.
    private func pruneSelection(ruleID: String) {
        let ids = Set(items(ruleID: ruleID).filter(\.isCleanable).map(\.id))
        checkedItems = checkedItems.filter { $0.ruleID != ruleID || ids.contains($0.itemID) }
        let actionIDs = Set(actions(ruleID: ruleID).filter(\.runnable).map(\.id))
        checkedActions = checkedActions.filter { $0.ruleID != ruleID || actionIDs.contains($0.actionID) }
    }

    // MARK: Environment state

    public func refreshDisk() {
        disk = DiskStatus.measure(environment.volumeURL)
    }

    /// Re-checks Full Disk Access; rescans rules that failed if access was just granted.
    public func refreshFullDiskAccess() async {
        let before = fullDiskAccess
        fullDiskAccess = environment.fullDiskAccess()
        if before != .granted, fullDiskAccess == .granted {
            let failed = results.values.filter { $0.error != nil }.map(\.ruleID)
            await scan(ruleIDs: failed)
        }
    }

    public func reloadHistory() {
        history = environment.history.entries().reversed()
    }

    public var totalReclaimedAllTime: Int64 { history.reduce(0) { $0 + max(0, $1.reclaimedBytes) } }

    // MARK: Settings

    public func updateSettings(_ change: (inout Settings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let newlyEnabled = Set(settings.disabledRuleIDs).subtracting(s.disabledRuleIDs)
        let filesChanged = s.fileRulesDiffer(from: settings)
        settings = s
        do {
            try environment.settingsStore.save(s)
            settingsError = nil
        } catch {
            settingsError = "Couldn't save settings: \(error.localizedDescription)"
        }
        // Drop checks for rules that are now disabled or items now ignored.
        let disabled = Set(s.disabledRuleIDs)
        let ignored = Set(s.ignoredPaths)
        checkedItems = checkedItems.filter { key in
            guard !disabled.contains(key.ruleID) else { return false }
            let item = results[key.ruleID]?.items.first { $0.id == key.itemID }
            return !(item?.path.map { ignored.contains($0.path) } ?? false)
        }
        checkedActions = checkedActions.filter { !disabled.contains($0.ruleID) }
        var toScan = newlyEnabled.filter { hasScanned && results[$0] == nil }
        if filesChanged, hasScanned {
            toScan.formUnion(rules.filter { $0.category == .files }.map(\.id))
        }
        if !toScan.isEmpty { Task { await scan(ruleIDs: Array(toScan)) } }
    }

    public func setRuleEnabled(_ on: Bool, ruleID: String) {
        updateSettings { s in
            s.disabledRuleIDs.removeAll { $0 == ruleID }
            if !on { s.disabledRuleIDs.append(ruleID) }
        }
    }

    public func ignore(_ item: Item) {
        guard let path = item.path?.path else { return }
        updateSettings { s in if !s.ignoredPaths.contains(path) { s.ignoredPaths.append(path) } }
    }

    public func unignore(path: String) {
        updateSettings { s in s.ignoredPaths.removeAll { $0 == path } }
    }

    // MARK: Fixture-only automation (screenshots / end-to-end checks)

    /// `--demo review` opens the Quick-clean review sheet after the first scan; `--demo clean` also confirms it.
    /// Ignored unless running against the fixture world, so it can never clean the real machine.
    public func runDemo(_ step: String) async {
        guard environment.isFixture else { return }
        if step.hasPrefix("hibernate") {
            await runHibernateDemo(confirm: step == "hibernate")
            return
        }
        if step.hasPrefix("offload") || step.hasPrefix("restore") {
            await runOffloadDemo(step)
            return
        }
        if !hasScanned { await scanAll() }
        await quickClean()
        if step == "clean" { await confirmClean() }
    }
}
