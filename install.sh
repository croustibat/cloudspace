#!/bin/bash
# Major Tom installer: downloads a prebuilt release from GitHub and installs it. No Xcode needed, never uses sudo.
#
#   curl -fsSL https://raw.githubusercontent.com/tjlondon-npauctions/majortom/main/install.sh | bash
#
# Options (when piping, pass them after `bash -s --`, e.g. `... | bash -s -- --dir ~/Applications`):
#   --version X     install release X (e.g. 1.0.0) instead of the latest
#   --dir PATH      install MajorTom.app into PATH (default: /Applications, or ~/Applications if that isn't writable)
#   --uninstall     remove MajorTom.app and the `majortom` command link; your settings and history are kept
#   -h, --help      show this help
#
# What it does, in order:
#   1. checks this Mac is supported (macOS 15 or later, Apple Silicon or Intel)
#   2. downloads MajorTom-<version>.zip and its .sha256 file from the GitHub release into a temporary folder
#   3. verifies the SHA-256 checksum and the app's (ad-hoc) code signature, and unpacks it there
#   4. quits a running copy of Major Tom at the install location (asks it to quit; never force-kills it)
#   5. moves the new app into place, replacing the old one only once the new one is ready
#   6. removes the quarantine attribute from the installed MajorTom.app (and nothing else); see the README
#   7. links the `majortom` command into ~/.local/bin or ~/bin if one of them is on your PATH
# Re-run it any time to update. Nothing is changed if any step fails.
#
# Testing hooks (for developing this script; you don't need them):
#   MAJORTOM_INSTALL_BASE_URL         where releases live instead of GitHub (http(s):// or file://); files are read
#                                     from <base>/download/v<version>/, and <base>/latest must redirect to .../v<version>
#   MAJORTOM_INSTALL_FAKE_OS_VERSION  pretend to be this macOS version (e.g. 14.6)
#   MAJORTOM_INSTALL_FAKE_ARCH        pretend to be this architecture (e.g. ppc)

# Everything runs from main(), called on the last line, so a partially downloaded script does nothing.
set -euo pipefail

REPO="tjlondon-npauctions/majortom"
APP_NAME="MajorTom.app"
APP_EXECUTABLE="MajorTom"        # CFBundleExecutable: identifies a Major Tom bundle before anything is replaced
BUNDLE_ID="uk.co.tom-jordan.majortom"
CLI_IN_BUNDLE="Contents/Helpers/majortom"
# What the release is built for. scripts/release.sh checks these against the built binary.
MIN_MACOS="15.0"
SUPPORTED_ARCHS="arm64 x86_64"

DEFAULT_BASE_URL="https://github.com/$REPO/releases"
BASE_URL="${MAJORTOM_INSTALL_BASE_URL:-$DEFAULT_BASE_URL}"

MODE="install"
WORK_DIR=""       # temporary staging folder, removed on exit
INCOMING=""       # the new app, copied next to the old one just before the swap
BACKUP=""         # the previous app while it's being replaced, restored if the swap fails
TARGET=""

say()  { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install.sh [--version X] [--dir PATH] [--uninstall]

  --version X     install release X (e.g. 1.0.0) instead of the latest
  --dir PATH      install MajorTom.app into PATH (default: /Applications, or ~/Applications if not writable)
  --uninstall     remove MajorTom.app and the `majortom` command link; your settings and history are kept

When piping into bash, pass options after `bash -s --`, e.g.
  curl -fsSL https://raw.githubusercontent.com/tjlondon-npauctions/majortom/main/install.sh | bash -s -- --version 1.0.0
EOF
}

cleanup() {
    local status=$?
    if [[ -n "$BACKUP" && -e "$BACKUP" ]]; then
        # The swap didn't finish: put the previous version back.
        if [[ ! -e "$TARGET" ]]; then mv "$BACKUP" "$TARGET" 2>/dev/null || true; else rm -rf "$BACKUP"; fi
        say "Kept the previously installed version at $TARGET." >&2
    fi
    if [[ -n "$INCOMING" && -e "$INCOMING" ]]; then rm -rf "$INCOMING"; fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
    if [[ $status -ne 0 && "$MODE" == "install" ]]; then
        say "Installation did not complete; the installed app (if any) was not changed." >&2
    fi
}

# --- checks -----------------------------------------------------------------------------------------------------

# Succeeds when version $1 >= version $2 (numeric, dot-separated).
version_at_least() {
    local IFS=.
    # shellcheck disable=SC2206  # word-splitting on dots is the point
    local a=($1) b=($2) i
    for i in 0 1 2; do
        local x="${a[$i]:-0}" y="${b[$i]:-0}"
        if ((10#$x > 10#$y)); then return 0; fi
        if ((10#$x < 10#$y)); then return 1; fi
    done
    return 0
}

check_system() {
    [[ "$(uname -s)" == "Darwin" ]] || die "Major Tom is a macOS app; this isn't a Mac."
    local os arch
    os="${MAJORTOM_INSTALL_FAKE_OS_VERSION:-$(sw_vers -productVersion)}"
    arch="${MAJORTOM_INSTALL_FAKE_ARCH:-$(uname -m)}"
    [[ "$os" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "couldn't read the macOS version (got '$os')."
    version_at_least "$os" "$MIN_MACOS" ||
        die "Major Tom needs macOS $MIN_MACOS or later; this Mac runs macOS $os."
    case " $SUPPORTED_ARCHS " in
        *" $arch "*) ;;
        *) die "Major Tom is built for $SUPPORTED_ARCHS; this Mac is $arch." ;;
    esac
    say "macOS $os on $arch: supported."
}

# A Major Tom bundle (not just anything called MajorTom.app)?
is_major_tom() {
    [[ -d "$1" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist" 2>/dev/null)" == "$APP_EXECUTABLE" ]]
}

bundle_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true
}

# --- downloading ------------------------------------------------------------------------------------------------

fetch() { # url, output file
    local protocols="=https"
    if [[ "$BASE_URL" != "$DEFAULT_BASE_URL" ]]; then protocols="=https,http,file"; fi
    curl --fail --silent --show-error --location --proto "$protocols" --retry 2 --output "$2" "$1" ||
        die "download failed: $1"
}

latest_version() {
    # GitHub redirects .../releases/latest to .../releases/tag/v<version>; read the tag from where it lands.
    local landed
    local protocols="=https"
    if [[ "$BASE_URL" != "$DEFAULT_BASE_URL" ]]; then protocols="=https,http,file"; fi
    landed="$(curl --fail --silent --show-error --location --proto "$protocols" --head --output /dev/null \
        --write-out '%{url_effective}' "$BASE_URL/latest")" || die "couldn't find the latest release at $BASE_URL"
    landed="${landed##*/}"
    [[ "$landed" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "couldn't find the latest release at $BASE_URL (got '$landed')"
    printf '%s\n' "${landed#v}"
}

sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

# --- quitting a running copy ------------------------------------------------------------------------------------

# Escapes a path for use in an extended regular expression.
regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

# PIDs of Major Tom processes running from the app at $1 (only that copy, not one elsewhere).
pids_running_from() {
    pgrep -f "^$(regex_escape "$1")/Contents/MacOS/$APP_EXECUTABLE( |\$)" 2>/dev/null || true
}

quit_running_copy() { # app path
    local pids pid waited=0
    pids="$(pids_running_from "$1")"
    [[ -n "$pids" ]] || return 0
    step "Asking the running Major Tom ($1) to quit"
    for pid in $pids; do
        # The same as choosing Quit: a quit request to that one process. It can clean up and save first.
        osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate()" \
            >/dev/null 2>&1 || true
    done
    while [[ -n "$(pids_running_from "$1")" ]]; do
        if ((waited >= 20)); then
            die "Major Tom is still running from $1. Quit it (menu bar icon > Quit) and run this again."
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
}

# --- the `majortom` command -------------------------------------------------------------------------------------

# User-writable bin folders in your home that are on PATH, in order of preference.
bin_dirs_on_path() {
    local dir
    for dir in "$HOME/.local/bin" "$HOME/bin"; do
        case ":$PATH:" in *":$dir:"*) [[ -d "$dir" && -w "$dir" ]] && printf '%s\n' "$dir" ;; esac
    done
    return 0
}

# A `majortom` link we made (points into a MajorTom.app), safe to replace or remove.
is_our_link() {
    [[ -L "$1" ]] && [[ "$(readlink "$1")" == *"/$APP_NAME/$CLI_IN_BUNDLE" ]]
}

link_cli() {
    local dir link
    dir="$(bin_dirs_on_path | head -n 1)"
    if [[ -z "$dir" ]]; then
        say "Command line tool: $TARGET/$CLI_IN_BUNDLE"
        say "  (no ~/.local/bin or ~/bin on your PATH; to use it as 'majortom', link it into a folder on your PATH:"
        say "   ln -s \"$TARGET/$CLI_IN_BUNDLE\" ~/.local/bin/majortom)"
        return 0
    fi
    link="$dir/majortom"
    if [[ -e "$link" || -L "$link" ]] && ! is_our_link "$link"; then
        say "Not linking the command line tool: $link already exists and isn't from Major Tom."
        say "  It is at $TARGET/$CLI_IN_BUNDLE"
        return 0
    fi
    ln -sfn "$TARGET/$CLI_IN_BUNDLE" "$link"
    say "Command line tool: $link -> $TARGET/$CLI_IN_BUNDLE"
}

# --- install / uninstall ----------------------------------------------------------------------------------------

default_dir() {
    if [[ -w /Applications ]]; then printf '/Applications\n'; else printf '%s/Applications\n' "$HOME"; fi
}

install_app() { # requested version (may be empty), install dir
    local version="$1" dir="$2"
    check_system

    if [[ -z "$version" ]]; then
        step "Finding the latest release"
        version="$(latest_version)"
    fi
    local zip="MajorTom-$version.zip"
    local url="$BASE_URL/download/v$version"
    say "Major Tom $version"

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/majortom-install.XXXXXX")"
    step "Downloading $url/$zip"
    fetch "$url/$zip" "$WORK_DIR/$zip"
    fetch "$url/$zip.sha256" "$WORK_DIR/$zip.sha256"

    step "Verifying the SHA-256 checksum"
    local expected actual
    expected="$(awk 'NR == 1 { print tolower($1) }' "$WORK_DIR/$zip.sha256")"
    actual="$(sha256_of "$WORK_DIR/$zip")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "the checksum file is not a SHA-256 checksum."
    [[ "$actual" == "$expected" ]] || die "checksum mismatch for $zip (expected $expected, got $actual). Not installing."
    say "OK $actual"

    step "Unpacking"
    mkdir "$WORK_DIR/unpacked"
    ditto -x -k "$WORK_DIR/$zip" "$WORK_DIR/unpacked" || die "couldn't unpack $zip."
    local staged="$WORK_DIR/unpacked/$APP_NAME"
    is_major_tom "$staged" || die "$zip doesn't contain $APP_NAME."
    [[ "$(bundle_version "$staged")" == "$version" ]] ||
        die "$zip contains version '$(bundle_version "$staged")', expected $version."
    [[ -x "$staged/$CLI_IN_BUNDLE" ]] || die "$zip is missing the command line tool."
    codesign --verify --strict "$staged" 2>/dev/null || die "the app's code signature doesn't verify; not installing."

    TARGET="$dir/$APP_NAME"
    if [[ ! -d "$dir" ]]; then mkdir -p "$dir" || die "couldn't create $dir."; fi
    [[ -w "$dir" ]] || die "$dir isn't writable (this installer never uses sudo). Try --dir ~/Applications."
    if [[ -e "$TARGET" || -L "$TARGET" ]]; then
        is_major_tom "$TARGET" || die "$TARGET exists but isn't Major Tom; not touching it."
        say "Replacing Major Tom $(bundle_version "$TARGET") at $TARGET"
    fi

    # Copy into the destination folder first (same volume, so the final step is a rename), then swap.
    step "Installing to $TARGET"
    INCOMING="$dir/.MajorTom-incoming-$$.app"
    ditto "$staged" "$INCOMING" || die "couldn't copy the app into $dir."
    quit_running_copy "$TARGET"
    if [[ -e "$TARGET" ]]; then
        BACKUP="$dir/.MajorTom-previous-$$.app"
        mv "$TARGET" "$BACKUP" || { BACKUP=""; die "couldn't move the old app aside."; }
    fi
    mv "$INCOMING" "$TARGET" || die "couldn't move the app into place."
    INCOMING=""
    if [[ -n "$BACKUP" ]]; then rm -rf "$BACKUP"; BACKUP=""; fi

    # Only the app we just installed; no other file is touched. See the README for why.
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

    link_cli

    say ""
    say "Major Tom $version is installed at $TARGET"
    say ""
    say "Next steps:"
    say "  1. Open it:  open \"$TARGET\""
    say "  2. Optional but recommended: System Settings > Privacy & Security > Full Disk Access, turn on Major Tom"
    say "     (without it the Trash and some app data can't be measured). After an update macOS may ask again."
    say "  3. Read what each item costs before you clean it. Nothing is removed without your review."
    say ""
    say "To update later, run the same install command again."
}

uninstall_app() { # install dir (may be empty: look in the usual places)
    local dir="$1" found=0 app link
    local -a candidates
    if [[ -n "$dir" ]]; then candidates=("$dir/$APP_NAME"); else candidates=("/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"); fi
    for app in "${candidates[@]}"; do
        [[ -e "$app" ]] || continue
        if ! is_major_tom "$app"; then say "$app isn't Major Tom; leaving it."; continue; fi
        TARGET="$app"
        quit_running_copy "$app"
        rm -rf "$app"
        say "Removed $app"
        found=1
    done
    for link in "$HOME/.local/bin/majortom" "$HOME/bin/majortom"; do
        if is_our_link "$link"; then rm -f "$link"; say "Removed $link"; fi
    done
    [[ $found -eq 1 ]] || say "No Major Tom app found in: $candidates"
    say ""
    say "Your settings and history were kept:"
    say "  $HOME/Library/Application Support/MajorTom"
    say "  $HOME/Library/Preferences/$BUNDLE_ID.plist"
    say "Delete those yourself if you don't want them. If you had turned on 'Open at login', remove Major Tom from"
    say "System Settings > General > Login Items."
}

main() {
    local version="" dir="" uninstall=0
    while (($#)); do
        case "$1" in
            --version) [[ $# -ge 2 ]] || die "--version needs a value, e.g. --version 1.0.0"; version="${2#v}"; shift ;;
            --version=*) version="${1#--version=}"; version="${version#v}" ;;
            --dir) [[ $# -ge 2 ]] || die "--dir needs a folder"; dir="$2"; shift ;;
            --dir=*) dir="${1#--dir=}" ;;
            --uninstall) uninstall=1 ;;
            -h | --help) usage; exit 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    if [[ -n "$version" && ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "--version takes a version like 1.0.0 (got '$version')."
    fi
    if [[ -n "$dir" ]]; then
        [[ "$dir" == /* ]] || dir="$PWD/$dir"
        dir="${dir%/}"
    fi
    [[ "$(id -u)" -ne 0 ]] || die "don't run this as root or with sudo; it installs for your user."

    trap cleanup EXIT
    if ((uninstall)); then
        MODE="uninstall"
        [[ -z "$version" ]] || die "--uninstall doesn't take --version."
        uninstall_app "$dir"
    else
        install_app "$version" "${dir:-$(default_dir)}"
    fi
}

main "$@"
