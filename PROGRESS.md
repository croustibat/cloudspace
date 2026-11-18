# Progress

Short record per milestone. Lasting guidance (conventions, gotchas, how to extend) lives in `CLAUDE.md`; the
behaviour itself in `SPEC.md`. All milestones were built and verified in November 2026.
"Real machine" below means the development Mac, used for scan/list-only checks; nothing real was cleaned.

## M1 — Core + CLI
- **Built:** package, scanner (`st_blocks`, parallel, inode de-dup, cache), 25 catalogue rules, clean engine +
  `PathValidator`, history, settings, CLI.
- **Verified:** 38 tests; real machine scan-only: full scan under 10 s, sizes matched independent `du` estimates.
- **Open:** review-tier `.trash` items only dry-run tested on the real machine.

## M2 — Ground Control UI
- **Built:** `GroundControl` model target, main window, review → confirm → measured result flow, history,
  settings, Full Disk Access banner, fixture mode and `--snapshot` dev aids.
- **Verified:** 52 tests; bundled app scan-only on the real machine; fixture `--demo clean`
  end to end; snapshots light/dark.

## M3 — Project hibernation
- **Built:** project discovery/analysis/sizing, per-project hibernate rule through the normal clean path,
  hibernation records with restore commands, Projects view + Settings tab, `majortom projects`.
- **Verified:** 66 tests (byte-identical survivors after hibernation, refusals); real machine list-only
  (project discovery, stale detection and strippable sizes checked by hand).

## M4 — Menu bar + alerts
- **Built:** `SpaceWatch` (cheap free-space checks, one alert per crossing), menu bar popover, notifications and
  login item behind opt-in toggles, weekly rescan.
- **Verified:** 80 tests with fake notifier/login item/clock; fixture lifecycle check; real menu bar scan-only.
- **Open:** real notifications, the login item and the notification's Quick Clean action only exercised via fakes.

## M5 — General cleanup + app icon
- **Built:** large/old files, installer leftovers, orphaned app data (Trash only, review tier), partial results
  for privacy-protected folders, Quick Look, app icon (`scripts/make-icon.swift`, candidate "Orbit").
- **Verified:** 102 tests; real machine scan-only (thresholds tuned after a
  low-threshold run surfaced editor media).
- **Open:** orphan matching in `~/Library/Containers` only fixture-tested (no Full Disk Access in the dev shell).

## M6 — NAS offload
- **Built:** offload engine (tar/plain copy, uncached verification, manifests, `RENAME_EXCL`, Trash last),
  restore, share import, Offload/Offloaded views, `majortom offload`.
- **Verified:** 130 tests incl. failure injection; opt-in real-share round trip (project as tar + a large movie
  file, restored identical; corrupted run left source intact); real machine list-only.
- **Open:** one NSTableView reentrancy warning logged when the Offload list first fills.

## Portability (after M6)
- **Built:** no machine-specific defaults: detected project roots (or an "Add Project Folder…" empty state),
  no default NAS folder ("Choose NAS Folder…" empty state; version-less settings files keep `/Volumes/MajorTom`),
  own bundle-ID prefixes as a setting, developer-tool stubs treated as missing, wider tool PATH, `--fixture-empty`,
  `scripts/install.sh`, `OUT_DIR`/`BUNDLE_ID` for `bundle.sh`, NAS e2e test takes any `/…/_devtest`.
- **Verified:** 144 tests (empty-home rules with absent/failing/silent tools, partial toolchains, detection,
  legacy settings, no-destination offload, model on an empty home); real machine scan-only unchanged (saved
  settings honoured, existing share still accepted, settings/history files untouched); fixture-empty
  snapshots of both empty states; `install.sh` tried against temp folders and `--dry-run` only.

## iCloud Drive destination (cloudspace fork)
- **Built:** a folder inside iCloud Drive (`~/Library/Mobile Documents/…`) is accepted as the offload destination
  next to a mounted network share (`VolumeStatus.isICloud`, `ICloudDrive`); other local folders are still refused.
  `CloudStorage` seam + `OffloadEngine.evictLocalCopies`: frees the local copy of an offloaded payload only once
  macOS reports it uploaded (dry run by default, `manifest.json` never evicted, nothing deleted, logged to history).
  Restore adds the re-download of an evicted archive to its free-space check; items over iCloud Drive's 50 GB file
  limit are refused before copying. CLI `majortom offload --evict [--execute]`; "Free Local Copies" banner in the
  Offloaded view.
- **Verified:** 201 tests (9 new, fake iCloud folder + `FakeCloudStorage`); the macOS mechanism itself checked once
  on a real Mac with a 5 MB throwaway file in iCloud Drive (uploaded → evicted to 0 bytes on disk → read back
  identical). No real offload to iCloud Drive has been run yet.
- **Open:** UI wording still says "NAS" in most places; no automatic eviction when an upload finishes; the offload
  copy needs the item's size free on this Mac until it is uploaded and evicted.

## Ideas / not built
- Real-life check of notifications, login item and the notification's Quick Clean action.
- Know when launched as a login item (currently the window always opens).
- Orphan matching for Group Containers and Preferences plists (never touched today); Containers needs FDA.
- Claude desktop data: a real clean action for its cache subfolders (report-only in v1).
- Hard-link-aware project sizes across projects (pnpm overstatement), APFS clone detection.
- Respect `NVM_DIR`, `PNPM_HOME`/`pnpm store path`, `HOMEBREW_CACHE`, `GRADLE_USER_HOME` overrides.
- Universal (arm64 + x86_64) build option in `bundle.sh`; Developer ID signing/notarisation for managed Macs.
- Offload: full-file checksum option for huge files, compression, scheduled offloads, emptying the Trash
  for offloaded items only.
- Synology `#recycle` awareness (report what partial-copy cleanups left there).
