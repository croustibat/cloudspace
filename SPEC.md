# Major Tom — spec (as built)

Personal, developer-oriented disk cleaner for macOS ("Ground Control to Major Tom: you're running out of space").
No sandbox, no App Store, ad-hoc signed (not notarised); released as a universal zip on GitHub Releases with a
`curl | bash` installer. Runs on macOS 15 or later (macOS 26 styling where available), Apple Silicon or Intel;
nothing in it assumes a particular user, folder layout, toolchain or NAS.

## Hard safety rules

1. **Never delete, move or modify real user files while developing or testing.** Tests and fixture mode run only
   against fake homes in the temp directory. Real-machine runs during development are scan / list / dry-run only.
2. The CLI and every core clean / hibernate / offload API default to **dry run**; acting needs an explicit flag.
3. Clean actions may only touch items the rule's resolver produces at clean time. Right before acting each path
   (and companion path) is re-validated: inside the home folder or an allow-listed system root
   (`/Library/Developer/CoreSimulator`); not `~`, `~/Library`, `~/Library/Caches`, `~/Documents`, `~/Desktop`,
   `~/Downloads`, a project root, a configured project folder or a volume root; inside the rule's base directory and
   not reached through a symlink escaping it. Trash-only rules additionally refuse paths inside a repository,
   project, package or app-managed library.
4. Never use `sudo`. Admin-only fixes are shown as a command for the user to run.
5. Every real clean, hibernation and offload is appended to `~/Library/Application Support/MajorTom/history.jsonl`.

## Stack and layout

Swift 6.2 (language mode 6, strict concurrency), SwiftUI, deployment target macOS 15 (macOS 26 SDK). Swift
package, no dependencies:

```
Sources/MajorTomCore/   scanner, rules, clean engine, path validation, projects, offload, settings, history, fixtures
Sources/GroundControl/  @MainActor @Observable view models, AppEnvironment (live / fixture), SpaceWatch
Sources/MajorTomApp/    SwiftUI app: main window + MenuBarExtra + Settings
Sources/majortom/       CLI: scan, rules, clean [--execute], history, projects, offload (JSON with --json)
Tests/                  Swift Testing, fixture-based (MajorTomCoreTests, GroundControlTests)
VERSION                 the version (single source of truth -> Info.plist -> app About tab and `majortom --version`)
install.sh              end-user installer: downloads a GitHub release, verifies SHA-256, installs, no sudo
scripts/bundle.sh       universal release build -> build/MajorTom.app (CLI in Contents/Helpers; icon; ad-hoc codesign)
scripts/release.sh      tests + clean build + checks + MajorTom-<version>.zip + .sha256; prints `gh release create`
scripts/install-from-source.sh  bundle + copy to /Applications (or ~/Applications), no sudo
scripts/make-icon.swift draws the app icon (CoreGraphics) -> design/AppIcon.icns
```

## Core model

```swift
enum Tier { case safe        // regenerates automatically, no user action needed
            case costsTime   // works again after a re-download / rebuild / re-setup the user will notice
            case review }    // user data or anything not automatically recoverable

struct Rule {
  id, title, category (xcode, android, javascript, packageManagers, ides, containers, system, projects, files)
  tier; impact; recovery; regenCost           // plain English, written for a developer
  method: .delete | .deleteContents | .trash | .command([String]) | .reportOnly   // items may override;
                                               // .deleteContents empties a folder and keeps it
  baseDirectories(ctx) -> [URL]                // every resolved path must be inside one
  resolve(ctx) async throws -> [Item]          // path, companion paths, size, last used, note, protected/flagged
  actions(ctx, items) -> [RuleAction]          // rule-level commands (e.g. `pnpm store prune`); runnable or show-only
  trashOnly: Bool                              // implied by the `files` category
}
```

- Items within a rule are individually selectable. Protected items are listed but never offered; flagged items are
  likely leftovers; report-only items and non-runnable actions are shown, never executed.
- `safe`/`costsTime` caches are deleted outright (trashing a cache frees nothing); `review` user data goes to the
  Trash. The owning tool's command is preferred where one exists.
- "Last used" = newest modification/access date over the item's top level (files rules: mtime, date added,
  Spotlight last-opened).
- Space reclaimed is measured from volume free space before and after, never summed from estimates.
- A rule whose folder or tool is missing resolves to nothing (a missing tool, a failing tool and empty output are
  all "nothing found"). Unreadable folders give a partial result naming the denied path.

## Scanner

- Allocated size (`lstat` `st_blocks × 512`), fts walk, top levels expanded so big trees size in parallel,
  cancellable, streaming per-rule results. No volume crossing, no symlink following. Decimal units in the UI.
- Each inode is counted once per scan (hard links). APFS clones aren't detected — hence measured reclaim.
- Results are cached per session; one rule can be rescanned alone. A full scan takes well under 30 s.

## Rule catalogue

| Rule | Source | Tier | Notes |
|---|---|---|---|
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` | safe | per project; flags entries whose `WorkspacePath` is gone |
| Xcode Archives | `…/Xcode/Archives/*/*.xcarchive` | review | Trash; offload candidate |
| Device support | `…/Xcode/* DeviceSupport/*` | safe | per platform + OS |
| Simulator devices | `xcrun simctl list -j devices` | costsTime | per device via `simctl delete`; "delete unavailable" action |
| Simulator runtimes | `xcrun simctl runtime list -j` | costsTime | via `simctl runtime delete`; warns on the only runtime; root-owned dyld cache report-only with the admin command |
| Simulator caches | `~/Library/Developer/CoreSimulator/Caches` | safe | |
| CocoaPods / SwiftPM caches | `~/Library/Caches/CocoaPods`, `…/org.swift.swiftpm` | safe | |
| npm cache | `~/.npm/_cacache`, `_npx`, `_logs` | safe | |
| pnpm store | `~/Library/pnpm/store/*` | costsTime | `pnpm store prune` offered as the safe action |
| Yarn / Bun caches | `~/Library/Caches/Yarn`, `~/.yarn/berry/cache`, `~/.bun/install/cache` | safe | |
| Node versions (nvm) | `~/.nvm/versions/node/*` | costsTime | default and active versions protected |
| Expo caches | `~/.expo/*cache*` | safe | |
| Gradle caches | `~/.gradle/caches/*`, `daemon`, `wrapper/dists/*` | costsTime | |
| Android SDK | `$ANDROID_HOME` (if inside home) or `~/Library/Android/sdk`: system images, platforms, build-tools, NDK | costsTime | images not used by any AVD flagged |
| Android emulators | `~/.android/avd` (`.ini` + `.avd`) | costsTime | |
| Cargo / rustup | `~/.cargo/registry/*`, `git/*`, `~/.rustup/toolchains/*` | costsTime | default toolchain protected |
| Homebrew cache | `~/Library/Caches/Homebrew` | safe | `brew cleanup --prune=all` action |
| JetBrains caches | `~/Library/Caches/JetBrains/*` | safe | older versions per product flagged |
| Docker | `docker system df` | review | report only + show-only prune commands |
| Claude desktop data | `~/Library/Application Support/Claude/*` | review | report only |
| App caches | `~/Library/Caches/*` not covered above | safe | skips `com.apple.*`; removed apps' caches go to the orphan rule; contents deleted, folders kept |
| Logs | `~/Library/Logs/*` | safe | contents deleted, folders kept |
| Trash | `~/.Trash/*` | review | needs Full Disk Access |
| Local snapshots | `tmutil listlocalsnapshots /` | review | report + show-only `tmutil deletelocalsnapshots` |
| Large files | Downloads, Movies, Desktop, Documents ≥ 500 MB | review | Trash only |
| Old files | same folders, ≥ 50 MB, untouched ≥ 365 days | review | Trash only |
| Installer leftovers | `.dmg/.pkg/.mpkg/.zip/.xip` in Downloads | review | Trash only; mounted images protected |
| Leftovers from removed apps | bundle-ID folders in Application Support, Caches, Containers (+ companions) | review | Trash only; see M5 |

## Settings (`~/Library/Application Support/MajorTom/settings.json`)

Tolerant JSON (missing keys keep defaults; `version` = 2). Project roots (unset = detect the usual folders:
`~/WebstormProjects`, `~/Projects`, `~/Developer`, `~/Code`, `~/dev`, `~/src`, `~/repos`, `~/workspace`, `~/git`,
`~/GitHub`, JetBrains/Android Studio/Xcode project folders, `~/Documents/GitHub`, `~/Documents/Projects`), stale days
(90), pinned / hidden projects, disabled rules, ignored items, low-space threshold (20 GB) + notifications (off),
weekly rescan (off), launch at login (off), large/old file thresholds, own bundle-ID prefixes, offload destination
(unset = offloading off; files without `version` keep the earlier implicit `/Volumes/MajorTom`), checksum cap (1 GB).

## Milestones (all complete)

**M1 — Core + CLI. ✅** Package, scanner, rule model, the catalogue above, clean engine with the safety checks,
history, settings, CLI, fixture tests (validation, inode de-dup, dry-run default, symlink escape).

**M2 — Ground Control UI. ✅** Window with disk gauge (used / free / reclaimable by tier), category sidebar, rule
list → item table (checkboxes, size, last used, notes) with impact / recovery / cost / removal method up front.
Quick clean = every cleanable `safe` item. Clean flow: review sheet (engine dry run, per-item skip reasons) →
confirm → progress → measured result. History, Settings, Full Disk Access banner. Fixture mode (`--fixture`).

**M3 — Project hibernation. ✅** Projects under the project roots: a `.git` dir always starts a project; other
markers (`package.json`, `Podfile`, `*.xcodeproj`, `build.gradle*`, `Cargo.toml`, `Package.swift`, `pubspec.yaml`,
`go.mod`, …) only outside one, so monorepos are one project. Activity = newest of last commit and newest source
change; stale after N days. Strippable: `node_modules`, `Pods`, `.next`, `.expo`, `.turbo`, `.gradle`/`.cxx`,
`target`, `.build`, `dist`/`build` only when git-ignored or a known output — never anything containing tracked
files. Hibernate reuses the clean review/measure/history path and records restore commands from lockfiles.
Git warnings (uncommitted, unpushed, no remote) are informational. Pin / hide per project. No project folders →
the Projects view asks for one.

**M4 — Menu bar + alerts. ✅** `MenuBarExtra` with free space, tier gauge, safe total, stale projects, Quick
Clean (opens the review sheet), Open, Rescan. Free-space check every 5 min and on wake (no scan); one notification
per threshold crossing (re-arms above threshold + max(2 GB, 10 %)), opt-in. Launch at login (`SMAppService`),
optional weekly rescan. Closing the window keeps the app in the menu bar.

**M5 — General cleanup. ✅** Large / old files and installer leftovers in Downloads, Movies, Desktop, Documents
(never inside projects, repos, packages, Photos/Music/TV libraries or editor render caches; each file in exactly
one rule), Quick Look and Reveal in Finder. Orphaned app data: bundle-ID-named folders whose app (and vendor) isn't
installed per /Applications, ~/Applications, system apps, Spotlight and LaunchServices; skips Apple, tooling, the
user's own bundle-ID prefixes and project names, anything touched in 30 days. All review tier, Trash only, never
in Quick clean.

**M6 — NAS offload. ✅** Destination = a folder the user chooses on a mounted network share (smbfs/afpfs/nfs/
webdav; local folders refused). Offload = copy (folders as one pax tar, single files as-is with SMB-safe names) →
fsync → read back uncached and verify (SHA-256 up to the cap, size + head/tail hash above) → manifest on the
share and locally → re-validate the original unchanged → move it to the Trash. Any failure keeps the original and
removes (or clearly marks) the partial copy. Candidates: stale projects (hibernate first offered), Xcode archives,
cold large/old files. Offloaded list with verified restore (to the original or another folder) and import of
manifests found on the share. No folder chosen → the Offload view asks for one.

## Done criteria for changes

`swift build` and `swift test` pass with no new warnings; `scripts/bundle.sh` produces an app that launches; the
safety rules hold; real-machine checks are scan-only; `PROGRESS.md` gets a short entry.
