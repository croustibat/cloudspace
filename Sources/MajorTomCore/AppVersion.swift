import Foundation

/// The version of this build. The single source of truth is the `VERSION` file at the repository root:
/// `scripts/bundle.sh` writes it into `MajorTom.app/Contents/Info.plist`, and both the app and the `majortom` CLI
/// (which ships inside the bundle at `Contents/Helpers/majortom`) read it back from there at run time. A build that
/// isn't inside an app bundle (`swift run`, `swift test`) reports `developmentVersion`.
public enum AppVersion {
    public static let developmentVersion = "dev"

    /// The version of the running executable, e.g. `1.0.0`, or `developmentVersion` outside a bundle.
    public static var current: String {
        guard let executable = Bundle.main.executableURL else { return developmentVersion }
        return version(forExecutable: executable) ?? developmentVersion
    }

    /// Reads `CFBundleShortVersionString` from the Info.plist of the app bundle that contains `executable`
    /// (`<App>.app/Contents/{MacOS,Helpers}/<name>`). Symlinks are resolved first, so a CLI symlinked into
    /// `~/.local/bin` still finds its bundle. Returns nil when the executable isn't inside a Major Tom bundle.
    public static func version(forExecutable executable: URL) -> String? {
        let contents = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent()   // MacOS or Helpers
            .deletingLastPathComponent()   // Contents
        guard contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleExecutable"] as? String == "MajorTom",
              let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty
        else { return nil }
        return version
    }
}
