#!/bin/zsh
# Builds a release of Major Tom for GitHub Releases. Does not publish anything: it prints the `gh release create`
# command for you to run after checking the output.
#
#   scripts/release.sh                 tests, clean universal build, zip, checksum
#   SKIP_TESTS=1 scripts/release.sh    skip `swift test`
#   OUT_DIR=/tmp/mt scripts/release.sh build somewhere other than build/
#
# Steps: swift test -> clean release build (scripts/bundle.sh, arm64 + x86_64, ad-hoc signed; the CLI is inside the
# bundle at Contents/Helpers/majortom) -> checks (version, minimum macOS and architectures agree with VERSION and
# with what ./install.sh accepts) -> MajorTom-<version>.zip (ditto, keeps the bundle intact) -> .sha256 file.
#
# Deliberately not signed with a Developer ID and not notarised; see README "Why isn't it notarised?".
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${OUT_DIR:-$ROOT/build}"
APP="$OUT/MajorTom.app"
REPO="tjlondon-npauctions/majortom"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "VERSION must be MAJOR.MINOR.PATCH (got '$VERSION')" >&2
  exit 1
fi
TAG="v$VERSION"
ZIP="$OUT/MajorTom-$VERSION.zip"
SUM="$ZIP.sha256"

fail() { print -r -- "release: $*" >&2; exit 1; }

# bundle.sh replaces $APP; don't pull it out from under a running copy.
if pgrep -f "^$APP/Contents/MacOS/" >/dev/null 2>&1; then
  fail "Major Tom is running from $APP. Quit it, or use OUT_DIR=<folder>."
fi

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  print "warning: the working tree has uncommitted changes; the release won't match a commit."
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  print "warning: tag $TAG already exists locally. Bump VERSION for a new release."
fi

if [[ -z "${SKIP_TESTS:-}" ]]; then
  print "==> swift test"
  swift test
fi

print "==> Clean release build ($VERSION)"
rm -rf -- "$ROOT/.build/apple" "$APP" "$ZIP" "$SUM"
swift package clean
ARCHS="arm64 x86_64" OUT_DIR="$OUT" "$ROOT/scripts/bundle.sh"

print "==> Checking the build"
APP_BIN="$APP/Contents/MacOS/MajorTom"
CLI_BIN="$APP/Contents/Helpers/majortom"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
# What ./install.sh promises users (it refuses older systems and other architectures).
INSTALL_MIN="$(sed -n 's/^MIN_MACOS="\(.*\)"$/\1/p' "$ROOT/install.sh")"
INSTALL_ARCHS="$(sed -n 's/^SUPPORTED_ARCHS="\(.*\)"$/\1/p' "$ROOT/install.sh")"
sorted() { print -r -- ${(j: :)${(o)${=1}}}; }

[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "Info.plist version isn't $VERSION"
[[ "$(plist CFBundleVersion)" == "$VERSION" ]] || fail "Info.plist build number isn't $VERSION"
[[ "$("$CLI_BIN" --version)" == "majortom $VERSION" ]] || fail "majortom --version doesn't say $VERSION"
for bin in "$APP_BIN" "$CLI_BIN"; do
  archs="$(lipo -archs "$bin")"
  [[ "$(sorted "$archs")" == "$(sorted "$INSTALL_ARCHS")" ]] ||
    fail "$bin is built for '$archs' but install.sh accepts '$INSTALL_ARCHS'"
  for minos in $(vtool -show-build "$bin" | awk '/minos/ { print $2 }'); do
    [[ "$minos" == "$INSTALL_MIN" ]] || fail "$bin needs macOS $minos but install.sh says $INSTALL_MIN"
  done
done
[[ "$(plist LSMinimumSystemVersion)" == "$INSTALL_MIN" ]] || fail "LSMinimumSystemVersion isn't $INSTALL_MIN"
codesign --verify --strict "$APP" || fail "code signature doesn't verify"
print "OK: version $VERSION, macOS $INSTALL_MIN+, $(lipo -archs "$APP_BIN"), ad-hoc signed"

print "==> Packaging"
# ditto keeps the bundle's symlinks, permissions and signature intact (plain `zip` can break them). Extended
# attributes (e.g. the local com.apple.provenance tag) aren't part of the signature and stay out of the zip.
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "${ZIP:t}" > "${SUM:t}")
(cd "$OUT" && shasum -a 256 -c "${SUM:t}" >/dev/null) || fail "checksum doesn't verify"

size="$(du -h "$ZIP" | cut -f1 | tr -d ' ')"
print
print "Release artefacts:"
print "  $ZIP ($size)"
print "  $SUM"
print "  sha256 $(cut -d' ' -f1 "$SUM")"
print
print "To publish (commit and push first; this creates tag $TAG on the default branch if it doesn't exist):"
print
print "  gh release create $TAG \\"
print "    \"$ZIP\" \\"
print "    \"$SUM\" \\"
print "    --repo $REPO --title \"Major Tom $VERSION\" --generate-notes"
print
print "Then check the one-line installer against it:"
print "  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- --dir \"\$(mktemp -d)\""
