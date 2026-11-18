import Foundation

enum XcodeRules {
    static var all: [Rule] { [derivedData, archives, deviceSupport, simulatorDevices, simulatorRuntimes, simulatorCaches] }

    static func xcode(_ ctx: RuleContext) -> URL { ctx.path("Library/Developer/Xcode") }

    static let derivedData = Rule(
        id: "xcode-derived-data",
        title: "Xcode DerivedData",
        category: .xcode,
        tier: .safe,
        impact: "Next build of each removed project is a full clean build; indexing and code completion are slow until the index rebuilds. Xcode must be quit or the project closed, or it will just rewrite parts while running.",
        recovery: "Automatically on the next build in Xcode / xcodebuild.",
        regenCost: "One full rebuild + re-index per project (minutes each).",
        method: .delete,
        baseDirectories: { [xcode($0).appending(path: "DerivedData")] },
        resolve: { ctx in
            let dir = xcode(ctx).appending(path: "DerivedData")
            return FS.children(of: dir, directoriesOnly: true).map { url in
                let name = url.lastPathComponent
                if name.hasSuffix(".noindex") {
                    return Item(displayName: name, path: url, note: "shared cache (module/symbol/compilation), used by all projects")
                }
                let project = name.split(separator: "-").dropLast().joined(separator: "-")
                let workspace = FS.readPlist(url.appending(path: "info.plist"))?["WorkspacePath"] as? String
                var note: String?
                var flagged = false
                if let workspace {
                    if FS.exists(URL(filePath: workspace)) {
                        note = workspace.replacingOccurrences(of: ctx.home.path, with: "~")
                    } else {
                        note = "source project no longer exists (\(workspace.replacingOccurrences(of: ctx.home.path, with: "~")))"
                        flagged = true
                    }
                }
                return Item(displayName: project.isEmpty ? name : project, path: url, note: note, isFlagged: flagged)
            }
        }
    )

    static let archives = Rule(
        id: "xcode-archives",
        title: "Xcode Archives",
        category: .xcode,
        tier: .review,
        impact: "You lose the dSYMs and built app for that release: crash reports from it can no longer be symbolicated locally, and you can't re-export or re-upload that exact build.",
        recovery: "None. An archive can only be rebuilt from the same commit, and won't be byte-identical (different UUIDs, so old crash logs still won't symbolicate).",
        regenCost: "Not recoverable; consider offloading to the NAS instead.",
        method: .trash,
        baseDirectories: { [xcode($0).appending(path: "Archives")] },
        resolve: { ctx in
            let dir = xcode(ctx).appending(path: "Archives")
            var items: [Item] = []
            for day in FS.children(of: dir, directoriesOnly: true) {
                let archives = FS.children(of: day, directoriesOnly: true).filter { $0.pathExtension == "xcarchive" }
                if archives.isEmpty {
                    items.append(Item(displayName: day.lastPathComponent + " (empty folder)", path: day))
                }
                for a in archives {
                    let info = FS.readPlist(a.appending(path: "Info.plist"))
                    let name = info?["Name"] as? String ?? a.deletingPathExtension().lastPathComponent
                    let props = info?["ApplicationProperties"] as? [String: Any]
                    let version = [props?["CFBundleShortVersionString"] as? String, (props?["CFBundleVersion"] as? String).map { "(\($0))" }]
                        .compactMap { $0 }.joined(separator: " ")
                    items.append(Item(displayName: "\(name) \(version) — \(day.lastPathComponent)".replacingOccurrences(of: "  ", with: " "),
                                      path: a,
                                      note: props?["CFBundleIdentifier"] as? String))
                }
            }
            return items
        }
    )

    static let deviceSupport = Rule(
        id: "xcode-device-support",
        title: "Device support files",
        category: .xcode,
        tier: .safe,
        impact: "Next time you connect that device (or one on that OS version) Xcode spends a few minutes copying symbols before you can debug on it. Symbolicating crash logs from that OS needs the files back.",
        recovery: "Automatically when a device with that OS is next connected to Xcode.",
        regenCost: "A few minutes of \"Copying shared cache symbols\" per device + OS.",
        method: .delete,
        baseDirectories: { ctx in
            FS.children(of: xcode(ctx), directoriesOnly: true).filter { $0.lastPathComponent.hasSuffix(" DeviceSupport") }
        },
        resolve: { ctx in
            let dirs = FS.children(of: xcode(ctx), directoriesOnly: true).filter { $0.lastPathComponent.hasSuffix(" DeviceSupport") }
            return dirs.flatMap { dir in
                let platform = dir.lastPathComponent.replacingOccurrences(of: " DeviceSupport", with: "")
                return FS.children(of: dir, directoriesOnly: true).map {
                    Item(displayName: $0.lastPathComponent, path: $0, note: platform)
                }
            }
        }
    )

    struct SimDevice: Decodable {
        var udid: String
        var name: String
        var state: String?
        var isAvailable: Bool?
        var dataPath: String?
        var lastBootedAt: String?
        var availabilityError: String?
    }

    static let simulatorDevices = Rule(
        id: "simulator-devices",
        title: "Simulator devices",
        category: .xcode,
        tier: .costsTime,
        impact: "The simulator and everything installed in it (apps, their data, keychain, settings, photos) is gone. You'd recreate the device in Xcode and reinstall your app; first boot of a new device is slow.",
        recovery: "Xcode > Window > Devices and Simulators > +, or `xcrun simctl create`. Then rebuild/run your app on it.",
        regenCost: "A minute to recreate + first boot; any test data inside is lost.",
        method: .reportOnly,
        baseDirectories: { [$0.path("Library/Developer/CoreSimulator/Devices")] },
        resolve: { ctx in
            guard let result = await ctx.runner.run(["xcrun", "simctl", "list", "-j", "devices"], timeout: 30),
                  result.succeeded else { return [] }
            struct Root: Decodable { var devices: [String: [SimDevice]] }
            guard let root = try? JSONDecoder().decode(Root.self, from: result.stdout) else { return [] }
            let iso = ISO8601DateFormatter()
            var items: [Item] = []
            for (runtime, devices) in root.devices {
                let os = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                    .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "(\\d) (\\d)", with: "$1.$2", options: .regularExpression)
                for d in devices {
                    let deviceDir = d.dataPath.map { URL(filePath: $0).deletingLastPathComponent() }
                    var notes: [String] = []
                    let unavailable = d.isAvailable == false
                    if unavailable { notes.append("unavailable (runtime missing)") }
                    if d.state == "Booted" { notes.append("booted — shut it down first") }
                    if d.lastBootedAt == nil { notes.append("never booted") }
                    items.append(Item(
                        id: d.udid,
                        displayName: "\(d.name) — \(os)",
                        path: deviceDir.flatMap { FS.exists($0) ? $0 : nil },
                        lastUsed: d.lastBootedAt.flatMap { iso.date(from: $0) },
                        note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                        methodOverride: .command(["xcrun", "simctl", "delete", d.udid]),
                        isFlagged: unavailable
                    ))
                }
            }
            return items
        },
        actions: { _, items in
            let unavailable = items.filter(\.isFlagged).count
            guard unavailable > 0 else { return [] }
            return [RuleAction(
                id: "delete-unavailable",
                title: "Delete \(unavailable) unavailable simulator\(unavailable == 1 ? "" : "s")",
                command: ["xcrun", "simctl", "delete", "unavailable"],
                tier: .safe,
                explanation: "Removes devices whose runtime is no longer installed. They can't boot anyway.")]
        }
    )

    struct SimRuntime: Decodable {
        var identifier: String
        var version: String?
        var build: String?
        var deletable: Bool?
        var sizeBytes: Int64?
        var lastUsedAt: String?
        var platformIdentifier: String?
        var runtimeIdentifier: String?
        var state: String?
    }

    static let coreSimulatorCaches = "/Library/Developer/CoreSimulator/Caches"

    static let simulatorRuntimes = Rule(
        id: "simulator-runtimes",
        title: "Simulator runtimes",
        category: .xcode,
        tier: .costsTime,
        impact: "Simulators on that OS version stop booting (they show as unavailable). Builds targeting that simulator OS won't run until you download the runtime again.",
        recovery: "Xcode > Settings > Components (or `xcodebuild -downloadPlatform iOS`).",
        regenCost: "Re-download ~7–9 GB per runtime, 10–30 min.",
        method: .reportOnly,
        baseDirectories: { _ in [URL(filePath: coreSimulatorCaches)] },
        resolve: { ctx in
            var items: [Item] = []
            if let result = await ctx.runner.run(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 30), result.succeeded,
               let runtimes = try? JSONDecoder().decode([String: SimRuntime].self, from: result.stdout) {
                let iso = ISO8601DateFormatter()
                var perPlatform: [String: Int] = [:]
                for r in runtimes.values { perPlatform[r.platformIdentifier ?? "", default: 0] += 1 }
                for r in runtimes.values {
                    let platform = platformName(r.platformIdentifier ?? r.runtimeIdentifier ?? "")
                    var notes: [String] = []
                    if perPlatform[r.platformIdentifier ?? ""] == 1 {
                        notes.append("only \(platform) runtime installed — no \(platform) simulator will boot without it")
                    }
                    if r.deletable == false { notes.append("not deletable (bundled with Xcode)") }
                    items.append(Item(
                        id: r.identifier,
                        displayName: "\(platform) \(r.version ?? "?")\(r.build.map { " (\($0))" } ?? "")",
                        path: nil,
                        size: r.sizeBytes ?? 0,
                        lastUsed: r.lastUsedAt.flatMap { iso.date(from: $0) },
                        note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                        methodOverride: .command(["xcrun", "simctl", "runtime", "delete", r.identifier]),
                        isProtected: r.deletable == false
                    ))
                }
            }
            // The simulator dyld shared caches live in a root-owned folder: report with the admin command.
            let caches = URL(filePath: coreSimulatorCaches)
            if ctx.allowedSystemRoots.contains(where: { isStrictlyInside(caches.path, $0.path) }), FS.exists(caches) {
                items.append(Item(
                    displayName: "Simulator dyld caches (system, needs admin)",
                    path: caches,
                    note: "regenerated on next simulator boot; root-owned, run the shown command yourself",
                    methodOverride: .reportOnly))
            }
            return items
        },
        actions: { ctx, items in
            guard items.contains(where: { $0.path?.path == coreSimulatorCaches }) else { return [] }
            return [RuleAction(
                id: "clear-dyld-caches",
                title: "Clear simulator dyld caches (admin)",
                command: ["sudo", "rm", "-rf", coreSimulatorCaches + "/dyld"],
                tier: .safe,
                explanation: "Rebuilt automatically the next time a simulator boots (that first boot is slower). Needs admin rights, so CloudSpace only shows the command.",
                runnable: false)]
        }
    )

    static func platformName(_ id: String) -> String {
        let l = id.lowercased()
        if l.contains("iphone") || l.contains("ios") { return "iOS" }
        if l.contains("watch") { return "watchOS" }
        if l.contains("appletv") || l.contains("tvos") { return "tvOS" }
        if l.contains("xr") || l.contains("vision") { return "visionOS" }
        return id
    }

    static let simulatorCaches = Rule(
        id: "simulator-caches",
        title: "Simulator caches",
        category: .xcode,
        tier: .safe,
        impact: "Simulators boot a bit slower the first time afterwards while CoreSimulator rebuilds its caches. Nothing inside your simulators is touched.",
        recovery: "Automatically on next simulator boot.",
        regenCost: "Slightly slower first boot.",
        method: .delete,
        baseDirectories: { [$0.path("Library/Developer/CoreSimulator/Caches")] },
        resolve: { ctx in childItems(ctx.path("Library/Developer/CoreSimulator/Caches"), directoriesOnly: false) }
    )
}
