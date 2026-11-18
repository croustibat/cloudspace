import AppKit

/// Development aid: `--snapshot <dir>` writes a PNG of every visible window (sheets included) once the
/// launch work is done, using the app's own drawing (no screen-recording permission needed).
/// `--appearance light|dark` forces the appearance; `--quit-after-snapshot` exits afterwards;
/// `--window-size 980x600` resizes the main window first.
@MainActor
enum Snapshotter {
    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func applyAppearance() {
        switch argument("--appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    /// A remembered frame on a sleeping external display stops SwiftUI from rendering; move to the main screen.
    static func bringWindowsOnScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = argument("--window-size").flatMap { arg -> NSSize? in
            let parts = arg.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
        }
        for window in NSApp.windows where window.isVisible && !window.isSheet {
            if let size, window.title.hasPrefix("CloudSpace") { window.setContentSize(size) }
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.minX + 40, y: max(f.minY, f.maxY - window.frame.height - 20)))
        }
    }

    /// `--open-menubar`: clicks our own status item so the menu bar popover is on screen for a snapshot.
    static func openMenuBarExtra() {
        func find(_ view: NSView) -> NSButton? {
            if let b = view as? NSButton, String(describing: type(of: b)).contains("StatusBar") { return b }
            for sub in view.subviews { if let b = find(sub) { return b } }
            return nil
        }
        for window in NSApp.windows where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            if let root = window.contentView, let button = find(root) ?? (root as? NSButton) {
                if ProcessInfo.processInfo.environment["MAJORTOM_SNAPSHOT_DEBUG"] != nil { NSLog("clicking %@", String(describing: type(of: button))) }
                button.performClick(nil)
                return
            }
        }
        NSLog("Snapshotter: no status item found")
    }

    /// `--check-window-lifecycle` (dev aid): closes the main window, checks the app keeps running as a
    /// menu bar app, reopens it three times and checks there is exactly one main window. Logs and exits.
    static func checkWindowLifecycle() {
        func mainWindows() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                let before = mainWindows().count
                mainWindows().forEach { $0.performClose(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated {
                        let closed = mainWindows().count
                        let policy = NSApp.activationPolicy() == .accessory ? "accessory" : "regular"
                        AppServices.shared.showMainWindow()
                        AppServices.shared.showMainWindow()
                        AppServices.shared.quickCleanFromShortcut()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            MainActor.assumeIsolated {
                                let model = AppServices.shared.model
                                let session = model.cleanSession.map { s -> String in
                                    if case .reviewing = s.phase { return "reviewing \(s.plan.itemCount) items" }
                                    return "other phase"
                                } ?? "none"
                                NSLog("lifecycle: before=%d afterClose=%d policyAfterClose=%@ afterReopen=%d policyNow=%@ cleanSession=%@ history=%d",
                                      before, closed, policy, mainWindows().count,
                                      NSApp.activationPolicy() == .accessory ? "accessory" : "regular", session, model.history.count)
                                AppDelegate.environment.fixture?.destroy()
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
    }

    static func snapshotIfRequested(label: String) async {
        guard let dir = argument("--snapshot") else { return }
        // `--snapshot-delay <seconds>` waits longer for slower views (e.g. offload candidates on the real machine).
        try? await Task.sleep(for: .seconds(argument("--snapshot-delay").flatMap(Double.init) ?? 1.5))
        let folder = URL(filePath: dir, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["MAJORTOM_SNAPSHOT_DEBUG"] != nil {
            for w in NSApp.windows {
                NSLog("window %@ %d %@ %@ min %@ fitting %@", String(describing: type(of: w)), w.isVisible ? 1 : 0, NSStringFromRect(w.frame),
                      w.identifier?.rawValue ?? "-", NSStringFromSize(w.contentMinSize), NSStringFromSize(w.contentView?.fittingSize ?? .zero))
            }
        }
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            let className = String(describing: type(of: window))
            if className.contains("NSStatusBarWindow") { continue }
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let kind = window.isSheet ? "sheet" : className.contains("MenuBarExtra") ? "menubar" : "window"
            let url = folder.appending(path: "\(label)-\(kind)-\(index).png")
            // MAJORTOM_SNAPSHOT_LAYER=1 renders the layer tree instead (when the window server has no fresh backing
            // store, e.g. while the displays are asleep).
            let ws = ProcessInfo.processInfo.environment["MAJORTOM_SNAPSHOT_LAYER"] != nil ? nil : windowServerSnapshot(window)
            if ProcessInfo.processInfo.environment["MAJORTOM_SNAPSHOT_DEBUG"] != nil {
                NSLog("snapshot %@: window server %@", className, ws == nil ? "failed, using layer render" : "ok")
            }
            let data = ws ?? layerSnapshot(view) ?? window.contentView.flatMap(layerSnapshot)
            if let data { try? data.write(to: url) } else { NSLog("Snapshotter: couldn't capture %@", className) }
        }
        if CommandLine.arguments.contains("--open-menubar") {
            // The status item itself isn't capturable; render its template icon (normal + low space) at 4×.
            let sheet = NSImage(size: NSSize(width: 100, height: 40), flipped: false) { _ in
                for (i, low) in [false, true].enumerated() {
                    let bg = NSRect(x: CGFloat(i) * 50, y: 0, width: 50, height: 40)
                    (i == 0 ? NSColor.white : NSColor(white: 0.15, alpha: 1)).setFill()
                    bg.fill()
                    let icon = MenuBarIcon.image(lowSpace: low)
                    let target = NSRect(x: bg.minX + 3, y: 4, width: 44, height: 32)
                    guard let cg = NSGraphicsContext.current?.cgContext else { return false }
                    cg.beginTransparencyLayer(auxiliaryInfo: nil)
                    icon.draw(in: target)
                    cg.setBlendMode(.sourceAtop)
                    cg.setFillColor(i == 0 ? NSColor.black.cgColor : NSColor.white.cgColor)
                    cg.fill(target)
                    cg.endTransparencyLayer()
                }
                return true
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 160, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = sheet.size
            if let rep, let gc = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gc
                sheet.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            }
            if let png = rep?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appending(path: "\(label)-menubar-icon.png"))
            }
        }
        if CommandLine.arguments.contains("--quit-after-snapshot") {
            // terminate(_:) waits for open sheets; this is a dev aid, so just clean up and exit.
            AppDelegate.environment.fixture?.destroy()
            exit(0)
        }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Asks the window server for this app's own window (works without screen-recording permission for
    /// one's own windows). The API is hidden from the macOS 26 SDK, so it's looked up at runtime.
    static func windowServerSnapshot(_ window: NSWindow) -> Data? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else { return nil }
        guard image.width > 1 else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Renders the view's layer tree (SwiftUI content doesn't draw through `cacheDisplay`).
    static func layerSnapshot(_ view: NSView) -> Data? {
        view.wantsLayer = true
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = ctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        if let bg = view.window?.backgroundColor.cgColor {
            cg.setFillColor(bg)
            cg.fill(CGRect(origin: .zero, size: size))
        }
        layer.render(in: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
