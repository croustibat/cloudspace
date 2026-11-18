import AppKit
import GroundControl
import MajorTomCore
import SwiftUI
import UserNotifications

@main
struct MajorTomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppServices.shared.model
    @State private var watch = AppServices.shared.watch

    var body: some Scene {
        Window(model.environment.isFixture ? "CloudSpace — Fixture" : "CloudSpace", id: "main") {
            ContentView()
                .environment(model)
                .environment(watch)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { AppServices.shared.mainWindowClosed() }
                .task {
                    if let step = AppDelegate.demoStep {
                        if step.hasPrefix("hibernate") { await model.scanAll() }
                        await model.runDemo(step)
                    } else if !model.hasScanned, !model.isScanning {
                        model.refreshDestination()
                        async let projects: Void = model.scanProjectsIfNeeded()
                        await model.scanAll()
                        await projects
                    }
                    if CommandLine.arguments.contains("--open-menubar") { Snapshotter.openMenuBarExtra() }
                    await Snapshotter.snapshotIfRequested(label: Snapshotter.argument("--snapshot-label") ?? "main")
                }
        }
        .defaultSize(width: 1240, height: 780)
        .commands { GroundControlCommands(model: model) }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .environment(watch)
        } label: {
            MenuBarLabel()
                .environment(watch)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(watch)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Chosen once at launch: the real machine, or a throwaway fixture tree (`--fixture` / `MAJORTOM_FIXTURE=1`).
    @MainActor static var environment: AppEnvironment { AppServices.shared.environment }

    /// `--demo review|clean` (fixture mode only) drives the clean flow for screenshots and end-to-end checks.
    @MainActor static var demoStep: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Snapshotter.applyAppearance()
            let services = AppServices.shared
            if !services.environment.isFixture, UserNotificationNotifier.isAvailable {
                // In-process only: lets a tap on our notification reach the app. Asks macOS for nothing.
                UNUserNotificationCenter.current().delegate = NotificationResponder.shared
            }
            services.watch.start()
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                              object: nil, queue: .main) { _ in
                Task { @MainActor in await AppServices.shared.watch.check() }
            }
        }
        if CommandLine.arguments.contains("--check-window-lifecycle") {
            MainActor.assumeIsolated { Snapshotter.checkWindowLifecycle() }
        }
        if Snapshotter.argument("--snapshot") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { Snapshotter.bringWindowsOnScreen() }
            }
        }
    }

    /// Closing the window leaves CloudSpace running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.environment.fixture?.destroy() }
    }
}

struct GroundControlCommands: Commands {
    let model: GroundControlModel

    var body: some Commands {
        CommandMenu("Clean") {
            Button(model.isScanning ? "Scanning…" : "Rescan All") { model.startScanAll() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isScanning)
            Divider()
            Button("Quick Clean…") { Task { await model.quickClean() } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.safeReclaimable == 0 || model.cleanSession != nil)
            Button("Review Selection…") { Task { await model.review() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.plan.isEmpty || model.cleanSession != nil)
            Button("Hibernate Selected Projects…") { Task { await model.reviewHibernation() } }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(model.hibernationPlan().isEmpty || model.cleanSession != nil)
            Button("Rescan Projects") { model.startProjectScan() }
                .disabled(model.isScanningProjects)
            Divider()
            Button("Offload Selected to NAS…") { Task { await model.reviewOffload() } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.checkedOffloadCandidates.isEmpty || model.offloadSession != nil)
            Divider()
            Button("Clear Selection") { model.clearSelection() }
                .keyboardShortcut(.escape, modifiers: [.command])
                .disabled(model.checkedItems.isEmpty && model.checkedActions.isEmpty)
        }
    }
}
