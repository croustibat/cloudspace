import AppKit
import GroundControl

/// Folder choosers shared by the Projects / Offload views and Settings.
@MainActor
enum FolderPickers {
    /// "Add Project Folder…": adds the chosen folder as a project root and rescans projects.
    static func addProjectRoot(_ model: GroundControlModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.environment.context.home
        panel.prompt = "Add"
        panel.message = "Choose a folder your projects live in (Major Tom looks several levels deep)."
        if panel.runModal() == .OK, let url = panel.url { model.addProjectRoot(url) }
    }

    /// "Choose NAS Folder…": the offload destination. Validation (mounted network share or iCloud Drive) happens on
    /// every check.
    static func chooseNASFolder(_ model: GroundControlModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.offloadDestination ?? URL(filePath: "/Volumes", directoryHint: .isDirectory)
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder on the mounted NAS share (connect it in Finder with ⌘K first), or a folder in iCloud Drive."
        if panel.runModal() == .OK, let url = panel.url { model.setOffloadDestination(url) }
    }
}
