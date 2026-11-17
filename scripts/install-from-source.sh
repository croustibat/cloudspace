#!/bin/zsh
# For developers: builds Major Tom from this checkout (scripts/bundle.sh) and copies MajorTom.app to
# /Applications, or to ~/Applications when /Applications isn't writable. Never uses sudo.
# (Users without Xcode: use the prebuilt release installer, ./install.sh at the repo root, instead.)
#
#   scripts/install-from-source.sh               build, then install
#   scripts/install-from-source.sh --no-build    install the existing build/MajorTom.app
#   scripts/install-from-source.sh --dry-run     print what would happen, change nothing
#   scripts/install-from-source.sh --dest DIR    install into DIR instead (e.g. a temp folder to try it out)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="MajorTom.app"
OUT="${OUT_DIR:-$ROOT/build}"   # same variable as bundle.sh
SOURCE="$OUT/$APP_NAME"
BUILD=1
DRY_RUN=0
DEST=""

while (( $# )); do
  case "$1" in
    --no-build) BUILD=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --dest) shift; DEST="${1:?--dest needs a folder}" ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

run() {
  if (( DRY_RUN )); then print -r -- "would run: $*"; else "$@"; fi
}

if [[ -z "$DEST" ]]; then
  if [[ -w /Applications ]]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
fi
TARGET="$DEST/$APP_NAME"

if (( BUILD )); then
  run "$ROOT/scripts/bundle.sh"
fi
if (( ! DRY_RUN )) && [[ ! -d "$SOURCE" ]]; then
  echo "No $SOURCE — run without --no-build first." >&2
  exit 1
fi

# Refuse to replace a copy that is running (quit it from its menu bar item first).
if pgrep -f "^$TARGET/Contents/MacOS/" >/dev/null 2>&1; then
  echo "Major Tom is running from $TARGET — quit it first (menu bar icon → Quit)." >&2
  exit 1
fi

if [[ ! -d "$DEST" ]]; then
  run mkdir -p "$DEST"
fi
if [[ -e "$TARGET" ]]; then
  # Only ever replace an existing Major Tom bundle, nothing else that happens to have the name.
  existing_exec="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_exec" != "MajorTom" ]]; then
    echo "$TARGET exists but isn't a Major Tom build; not touching it." >&2
    exit 1
  fi
  run rm -rf "$TARGET"
fi
run ditto "$SOURCE" "$TARGET"
# Built locally, so it carries no quarantine flag; clear it anyway in case build/ was copied from elsewhere.
run xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if (( DRY_RUN )); then print "Dry run: nothing was changed. Would install $TARGET"; exit 0; fi
print "Installed $TARGET"
print "Command line tool: $TARGET/Contents/Helpers/majortom (symlink it onto your PATH if you want it, e.g. ~/.local/bin)."
print "First run: open it, grant Full Disk Access in System Settings → Privacy & Security if you want the Trash and"
print "app Containers measured, and check Settings → Projects / NAS."
