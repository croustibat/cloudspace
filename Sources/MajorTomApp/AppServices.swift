import AppKit
import GroundControl
import MajorTomCore
import SwiftUI

/// App-wide objects shared by the main window, the menu bar extra, Settings and notification handling.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let model: GroundControlModel
    let watch: SpaceWatch
    /// Captured from SwiftUI (the always-present menu bar label) so AppKit callbacks can open the window.
    var openWindow: OpenWindowAction?

    private init() {
        let environment = AppEnvironment.fromProcess()
        model = GroundControlModel(environment: environment)
        let volume = environment.volumeURL
        let deps: SpaceWatch.Dependencies
        if environment.isFixture {
            // Fixture mode never asks macOS for anything: notifications are recorded, the login item is fake.
            deps = .init(freeSpace: { VolumeInfo.availableBytes(at: volume) },
                         notifier: RecordingNotifier(), loginItem: InMemoryLoginItem(), state: InMemoryAlertState())
        } else {
            deps = .init(freeSpace: { VolumeInfo.availableBytes(at: volume) },
                         notifier: UserNotificationNotifier(), loginItem: MainAppLoginItem(), state: DefaultsAlertState())
        }
        watch = SpaceWatch(model: model, dependencies: deps)
    }

    var environment: AppEnvironment { model.environment }

    /// Opens (or brings forward — `Window` scenes are single-instance) the main window.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && !$0.isSheet }),
           window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
        NSApp.activate()
    }

    /// Menu bar / notification "Quick Clean…": shows the window and opens the review sheet there.
    /// Nothing is cleaned until the user confirms in that sheet.
    func quickCleanFromShortcut() {
        showMainWindow()
        Task { await model.requestQuickClean() }
    }

    private var launchCheckDone = false

    /// SwiftUI sometimes restores a "no windows open" state for apps with a menu bar extra; launching
    /// CloudSpace should still show the window, so open it if it didn't appear by itself.
    func ensureMainWindowAtLaunch() {
        guard !launchCheckDone else { return }
        launchCheckDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let visible = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
                if !visible { self.showMainWindow() }
            }
        }
    }

    /// With the main window closed the app lives in the menu bar only (no Dock icon).
    func mainWindowClosed() {
        // The closing window is still "visible" while SwiftUI tears it down; look once it's gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                let open = NSApp.windows.contains { $0.isVisible && !$0.isSheet && $0.identifier?.rawValue.hasPrefix("main") == true }
                if !open { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}
