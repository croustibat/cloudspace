# Major Tom — notes for working on this repo

Personal macOS 26 disk cleaner for developers (SwiftUI app + menu bar + `majortom` CLI). Finds dev-tool caches,
explains what deleting each costs, removes only what the user confirms; also hibernates stale projects, lists
large/old files and removed apps' leftovers, and offloads to a NAS. `SPEC.md` is the spec (as built),
`PROGRESS.md` the per-milestone record, `README.md` the user-facing doc.

## Targets (Swift 6.2, language mode 6, strict concurrency, no dependencies)

- `Sources/MajorTomCore` — everything that touches the disk: model (`Model.swift`), `Scanner`/`DiskSizer`, rules
  (`Rules/`, one file per category), `CleanEngine` + `PathValidator`, `Projects/` (discovery, hibernation),
  `Offload/` (engine, tar, manifests, share checks), `Settings`, `History`, `FixtureWorld`. No UI imports.
- `Sources/GroundControl` — `@MainActor @Observable` view models (`GroundControlModel` + extensions for projects /
  offload, `SpaceWatch`, `CleanPlan`), `AppEnvironment` (live vs fixture). No SwiftUI.
- `Sources/MajorTomApp` — SwiftUI views only; `Snapshotter` (dev screenshots), `SystemServices` (notifications,
  login item). Logic belongs in GroundControl/Core so it can be tested.
- `Sources/MajorTomCLI` — the CLI's strict argument parser (per-command allowed flags in `CLI.commands`, usage
  text) and `CleanSelection` (`--item`/`--flagged` → exact items). Unknown/misspelt flags, missing values, repeated
  single-value flags and stray arguments are errors; a filter that matches nothing fails, never widens to the rule.
- `Sources/majortom` — CLI commands (`main.swift`). Read-only except `clean --execute`.
- `Tests/MajorTomCoreTests`, `Tests/GroundControlTests`, `Tests/MajorTomCLITests` — Swift Testing, fixture homes in
  `$TMPDIR` only.

## Hard safety rules (also while developing)

1. Never clean, trash, hibernate or offload anything real. Real-machine runs are scan/list only (`majortom scan`,
   `projects`, `offload`, dry-run `clean` without `--execute`, or the app without confirming anything).
2. Flows are exercised in fixture mode or tests: fake home in `$TMPDIR/MajorTomFixture-*` / `MajorTomTests-*`,
   simulated commands (`SimulatedRunner`/`FakeRunner`), fixture Trash folder (`FolderTrashRemover`), fake NAS.
3. Every clean API and the CLI default to dry run. Engines re-resolve the rule and only accept items its resolver
   produces now, then `PathValidator` re-checks each path (inside home or an allow-listed system root, not a
   protected folder / project root / volume root, no symlink escape) right before acting.
4. Review-tier user files (`files` category, `trashOnly` rules, offload originals) only ever go to the Trash.
5. No `sudo`, ever. Admin-only fixes are `RuleAction(runnable: false)` — shown for the user to run.
6. Don't rewrite `~/Library/Application Support/MajorTom/*` by hand; your own copy of the app may be running from
   `build/MajorTom.app` or `/Applications` — only quit instances you launched (use `OUT_DIR` to build elsewhere).

## Commands

```sh
swift build && swift test                       # 0 warnings expected; ~30 s of tests
scripts/bundle.sh                               # release -> build/MajorTom.app + build/majortom (ad-hoc signed)
OUT_DIR=/tmp/mt scripts/bundle.sh               # same, elsewhere (don't replace a running build/ copy)
scripts/install.sh [--dry-run] [--no-build] [--dest DIR]   # copy to /Applications or ~/Applications
swift run majortom scan|projects|offload [--json]           # real machine, read-only
build/MajorTom.app/Contents/MacOS/MajorTom --fixture [--fixture-empty] [--demo clean|hibernate|offload|…]
  --sidebar <projects|files|offload|offloaded|history> --snapshot DIR --snapshot-label X
  --snapshot-delay S --quit-after-snapshot [--appearance dark] [--open-settings --settings-tab nas]
MAJORTOM_NAS_E2E=/Volumes/<share>/_devtest swift test --filter NASEndToEnd   # opt-in, real share
```

`screencapture` isn't permitted from the agent shell: use `--snapshot` (the app renders its own windows to PNGs;
`MAJORTOM_SNAPSHOT_LAYER=1` when displays are asleep). Wrap app runs in `perl -e 'alarm 90; exec @ARGV' …`.

## Adding things

**A rule** (existing category):
1. Add a `static let` `Rule` in the category file under `Sources/MajorTomCore/Rules/` and list it in that enum's
   `all`. Fill `impact` / `recovery` / `regenCost` honestly; pick `tier` and `method`; `baseDirectories` must cover
   every path the resolver returns. Use `FS.children`, `childItems`, `wholeItem` (lstat, no symlinks followed).
2. Tools go through `ctx.runner.run([...])`; treat `nil` (not installed) and non-zero exit as "nothing found".
   Missing folders must resolve to `[]`; rule-level `actions` should be empty when there are no items.
3. Add its id to `RuleTests.catalogueIsComplete`, a fixture test in `RuleTests`, and it is automatically covered
   by `PortabilityTests.everyRuleFindsNothingInAnEmptyHome`. Optionally mirror it in `FixtureRules` (`FixtureWorld`).
**A category:** add a case to `RuleCategory` (`Model.swift`, with `title`), a `symbol` in `SidebarView.swift`'s
`RuleCategory` extension, a new `Rules/<Name>Rules.swift` enum, and include it in `RuleCatalogue.all`
(`SystemRules.swift`). Categories with rules appear in the sidebar and Settings → Rules automatically.
**A clean method:** add a case to `CleanMethod` (+ `summary`), handle it in `CleanEngine.perform` (validate paths
first, honour `execute` and `trashOnly`), then the UI switches in `RuleDetailView` (removal text) and
`CleanSheet` (badge). Add engine tests for dry run, execute (fixture only) and refusal paths.
**A setting:** property with default on `Settings`, a line in `init(from:)` (tolerant decoding: missing key →
default), mutate via `GroundControlModel.updateSettings`; add to `fileRulesDiffer` if it changes file-rule results.

## Conventions the code follows

- Sizes are allocated bytes (`st_blocks × 512`), shown in decimal units (`ByteFormat`). Reclaimed space is measured
  from volume free space before/after, never summed.
- Paths are stored with `~/` when inside home (`expandTilde`); compare standardized paths.
- `Item.methodOverride`, `isProtected` (never offered), `isFlagged` (likely leftover), `note` (why) carry per-item
  decisions; UI uses `Item.isCleanable` / `RuleResult.reclaimableSize`.
- Unreadable folders: throw `PartialResolution(items:message:deniedPaths:)`, not an error.
- Heavy filesystem work runs off the main actor (`offPool`, `Task.detached`); concurrent identical resolves share
  one walk (`InFlight`). Model mutations happen on the main actor only.
- Tests build their own fixture tree, never read the real home; git in fixtures uses `FixtureGit` isolation.
- Fixture-only dev aids (`--demo`, `--fixture-*`) must check `environment.isFixture`.

## Portability (any Mac, not just the author's)

- Project roots: `Settings.projectRoots == nil` means detect (`ProjectRootDetector`: ~/WebstormProjects,
  ~/Projects, ~/Developer, ~/Code, ~/src, ~/IdeaProjects, …, ~/Documents/GitHub). An explicit `[]` means none.
- Offload destination: no default; `nil` → Offload view asks for a folder (`DestinationCheck.notSet`). Settings
  files without a `version` key (pre-portability) keep the old implicit `/Volumes/MajorTom`.
- "Apps I build myself": `Settings.ownBundleIDPrefixes` (default `uk.co.tom-jordan.`) + project-name matching.
- `ProcessRunner` adds Homebrew (both prefixes), cargo, pnpm, Docker Desktop, OrbStack, MacPorts to PATH, and treats
  `/usr/bin/git`, `xcrun` & co. as missing when no Xcode/CLT is installed (they'd pop the install dialog).

## Gotchas found during the build

- pnpm hard links: project sizes are de-duplicated per project scan only, so hibernation overstates pnpm projects;
  the measured result is the truth.
- Simulator dyld cache (`/Library/Developer/CoreSimulator/Caches`) is root-owned: report-only + shown `sudo` command.
- Large files above `offloadChecksumCapMB` are verified by size + first/last 4 MiB hash on offload (restore checks all).
- Offload and Trash-only rules move originals to the Trash: space returns only once the Trash is emptied.
- Without Full Disk Access the Trash rule errors and `~/Library/Containers` is skipped by the orphan rule.
- Ad-hoc signing changes per build: privacy prompts (Documents/Desktop/Downloads) may reappear after `bundle.sh`.
- SwiftUI: vertically `fixedSize` text above a `List` draws the window blank; mutating the model inside a sidebar
  selection change trips NSTableView reentrancy — `await Task.yield()` first; rebuild tables via `.id(...)` rather
  than animating rows while sizes stream in. A remembered frame on a sleeping display stops rendering.
- Synology recycle bin: deletions on the share land in `#recycle`; Major Tom never touches it.
