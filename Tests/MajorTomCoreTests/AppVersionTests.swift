import Foundation
import Testing
@testable import MajorTomCore

@Suite("App version")
struct AppVersionTests {
    private func bundle(_ fixture: Fixture, executable: String = "MajorTom", version: String = "1.2.3") throws -> URL {
        let app = try fixture.dir("Apps/MajorTom.app")
        try fixture.plist("Apps/MajorTom.app/Contents/Info.plist",
                          ["CFBundleExecutable": executable, "CFBundleShortVersionString": version])
        try fixture.file("Apps/MajorTom.app/Contents/MacOS/MajorTom", bytes: 8)
        try fixture.file("Apps/MajorTom.app/Contents/Helpers/majortom", bytes: 8)
        return app
    }

    @Test func readsTheEnclosingBundlesVersion() throws {
        let fixture = try Fixture()
        let app = try bundle(fixture)
        #expect(AppVersion.version(forExecutable: app.appending(path: "Contents/MacOS/MajorTom")) == "1.2.3")
        #expect(AppVersion.version(forExecutable: app.appending(path: "Contents/Helpers/majortom")) == "1.2.3")
    }

    @Test func followsASymlinkedCLI() throws {
        let fixture = try Fixture()
        let app = try bundle(fixture)
        try fixture.symlink("bin/majortom", to: app.appending(path: "Contents/Helpers/majortom"))
        #expect(AppVersion.version(forExecutable: fixture.home.appending(path: "bin/majortom")) == "1.2.3")
    }

    @Test func outsideAMajorTomBundleThereIsNoVersion() throws {
        let fixture = try Fixture()
        #expect(AppVersion.version(forExecutable: try fixture.file("build/debug/majortom", bytes: 8)) == nil)
        let other = try bundle(fixture, executable: "SomethingElse")
        #expect(AppVersion.version(forExecutable: other.appending(path: "Contents/MacOS/MajorTom")) == nil)
    }

    /// `VERSION` is the single source of truth for releases: one line, plain `MAJOR.MINOR.PATCH`.
    @Test func versionFileIsPlainSemver() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "VERSION"), encoding: .utf8)
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == version + "\n")
        #expect(version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil, "VERSION is \(version)")
    }
}
