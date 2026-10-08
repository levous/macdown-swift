#!/usr/bin/env bash
#
# Builds, signs, notarizes and publishes a MacDown release, then updates the
# Homebrew cask in the tap.
#
#     Tools/release.sh 1.1             # release version 1.1
#     Tools/release.sh 1.1 --dry-run   # build and check everything, publish nothing
#
# A release:
#   1. bumps the version in project.yml and MacDownShared/Globals.swift,
#   2. runs the tests and builds the app with the Developer ID certificate,
#   3. notarizes and staples the app, and zips it,
#   4. commits the version bump, tags it, and pushes both,
#   5. creates a GitHub release with the zip attached,
#   6. writes Casks/macdown-swift.rb in the tap with the new version and
#      checksum, and pushes it.
#
# A dry run builds with the Developer ID certificate if there is one (ad hoc
# otherwise), skips notarization unless it can sign, leaves the version files
# as they were, and prints the cask instead of publishing anything.
#
# Requirements: Xcode, XcodeGen, the GitHub CLI (logged in), and for real
# releases a "Developer ID Application" certificate in the keychain plus
# notarization credentials stored with:
#
#     xcrun notarytool store-credentials macdown-notary \
#         --apple-id <apple id> --team-id <team id>
#
# Settings (environment variables):
#   SIGNING_IDENTITY  Certificate name; default: the first "Developer ID
#                     Application" identity in the keychain.
#   NOTARY_PROFILE    notarytool keychain profile; default: macdown-notary.
#   GITHUB_REPO       Repository for releases; default: levous/macdown-swift.
#   TAP_REPO          Homebrew tap repository; default: levous/homebrew-tap.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARY_PROFILE="${NOTARY_PROFILE:-macdown-notary}"
GITHUB_REPO="${GITHUB_REPO:-levous/macdown-swift}"
TAP_REPO="${TAP_REPO:-levous/homebrew-tap}"
CASK_NAME="macdown-swift"
BUNDLE_ID="io.github.levous.macdown-swift"

VERSION=""
DRY_RUN=false
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) echo "Unknown option: $argument" >&2; exit 1 ;;
        *) VERSION="$argument" ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || fail "usage: Tools/release.sh <version, e.g. 1.1> [--dry-run]"
TAG="v$VERSION"

# MARK: - Checks

step "Checking prerequisites"
for tool in xcodegen gh xcodebuild ditto shasum; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || fail "the GitHub CLI is not logged in (gh auth login)"

PROJECT_FILE="project.yml"
GLOBALS_FILE="Sources/MacDownShared/Globals.swift"
if $DRY_RUN; then
    [[ -z "$(git status --porcelain -- "$PROJECT_FILE" "$GLOBALS_FILE")" ]] \
        || fail "$PROJECT_FILE or $GLOBALS_FILE has uncommitted changes"
else
    [[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes"
    [[ "$(git branch --show-current)" == main ]] || fail "releases are made from main"
    git fetch -q origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
        || fail "main is not in sync with origin/main"
    ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
        || fail "tag $TAG already exists"
fi

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [[ -n "$SIGNING_IDENTITY" ]]; then
    TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$SIGNING_IDENTITY")"
    [[ -n "$TEAM_ID" ]] || fail "can't find the team ID in \"$SIGNING_IDENTITY\""
    echo "Signing as: $SIGNING_IDENTITY"
elif $DRY_RUN; then
    echo "No Developer ID certificate; the dry run signs ad hoc and skips notarization."
else
    fail "no \"Developer ID Application\" certificate in the keychain (set SIGNING_IDENTITY)"
fi
NOTARIZE=false
if [[ -n "$SIGNING_IDENTITY" ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        && NOTARIZE=true
    $NOTARIZE || $DRY_RUN \
        || fail "no notarytool credentials in profile \"$NOTARY_PROFILE\" (see the header of this script)"
fi

# MARK: - Version

CURRENT_BUILD="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' "$PROJECT_FILE")"
[[ -n "$CURRENT_BUILD" ]] || fail "can't find CURRENT_PROJECT_VERSION in $PROJECT_FILE"
BUILD=$((CURRENT_BUILD + 1))

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macdown-release.XXXXXX")"
# Put the version files back after a dry run, or if a release fails before
# the version bump is committed.
RESTORE_VERSION=true
cleanup() {
    if $RESTORE_VERSION; then
        cp "$WORK/$(basename "$PROJECT_FILE")" "$PROJECT_FILE" 2>/dev/null || true
        cp "$WORK/$(basename "$GLOBALS_FILE")" "$GLOBALS_FILE" 2>/dev/null || true
        xcodegen generate --quiet 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
cp "$PROJECT_FILE" "$GLOBALS_FILE" "$WORK/"

step "Setting version $VERSION (build $BUILD)"
sed -i '' -E \
    -e "s/^( *MARKETING_VERSION: )\"[^\"]*\"/\1\"$VERSION\"/" \
    -e "s/^( *CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$BUILD\"/" \
    "$PROJECT_FILE"
# The shell utility prints these; they must match the app's.
sed -i '' -E \
    -e "s/(shortVersion = )\"[^\"]*\"/\1\"$VERSION\"/" \
    -e "s/(bundleVersion = )\"[^\"]*\"/\1\"$BUILD\"/" \
    "$GLOBALS_FILE"
grep -q "MARKETING_VERSION: \"$VERSION\"" "$PROJECT_FILE" \
    && grep -q "shortVersion = \"$VERSION\"" "$GLOBALS_FILE" \
    || fail "couldn't update the version"

# MARK: - Build

step "Running tests"
swift test

step "Building"
xcodegen generate --quiet
DERIVED="$WORK/DerivedData"
SIGNING_SETTINGS=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
if [[ -n "$SIGNING_IDENTITY" ]]; then
    SIGNING_SETTINGS=(
        "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
        "DEVELOPMENT_TEAM=$TEAM_ID"
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
fi
xcodebuild -project MacDown.xcodeproj -scheme MacDown -configuration Release \
    -derivedDataPath "$DERIVED" "${SIGNING_SETTINGS[@]}" \
    clean build | grep -E "^(\*\*|error:|warning: .*[Ss]ign)" || true
APP="$DERIVED/Build/Products/Release/MacDown.app"
[[ -d "$APP" ]] || fail "the build failed"

step "Checking the app"
TOOL="$APP/Contents/SharedSupport/bin/macdown"
[[ -x "$TOOL" ]] || fail "the macdown shell utility is missing from the app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[[ "$(plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "unexpected bundle identifier"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" && "$(plist CFBundleVersion)" == "$BUILD" ]] \
    || fail "the app's version isn't $VERSION ($BUILD)"
[[ "$("$TOOL" --version)" == "MacDown $VERSION ($BUILD)" ]] \
    || fail "the shell utility reports \"$("$TOOL" --version)\", not $VERSION ($BUILD)"
codesign --verify --deep --strict "$APP" || fail "the app's signature is invalid"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    # Notarization rejects any executable without the hardened runtime or a
    # secure timestamp, including the embedded shell utility.
    for binary in "$APP" "$TOOL"; do
        details="$(codesign -dvv "$binary" 2>&1)"
        grep -q "Authority=$SIGNING_IDENTITY" <<<"$details" \
            || fail "$(basename "$binary") isn't signed with $SIGNING_IDENTITY"
        grep -q "flags=.*runtime" <<<"$details" \
            || fail "$(basename "$binary") doesn't use the hardened runtime"
        grep -q "^Timestamp=" <<<"$details" \
            || fail "$(basename "$binary") has no secure timestamp"
    done
fi

ZIP="$WORK/MacDown-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if $NOTARIZE; then
    step "Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
        | tee "$WORK/notary.log"
    grep -q "status: Accepted" "$WORK/notary.log" \
        || fail "notarization failed; see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP" || fail "Gatekeeper rejects the app"
    # Zip again so the download includes the stapled ticket.
    rm "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "$(basename "$ZIP"): $SHA256"

# MARK: - Cask

CASK="$WORK/$CASK_NAME.rb"
cat > "$CASK" <<EOF
cask "$CASK_NAME" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$GITHUB_REPO/releases/download/v#{version}/MacDown-#{version}.zip"
  name "MacDown (Swift)"
  desc "Open source Markdown editor with live preview"
  homepage "https://github.com/$GITHUB_REPO"

  # The original MacDown installs an app with the same name.
  conflicts_with cask: "macdown"
  depends_on macos: :sequoia

  app "MacDown.app"
  binary "#{appdir}/MacDown.app/Contents/SharedSupport/bin/macdown"

  # ~/Library/Application Support/MacDown is shared with the original
  # MacDown, so it is left alone.
  zap trash: [
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
    "~/Library/WebKit/$BUNDLE_ID",
  ]
end
EOF
if $DRY_RUN; then
    step "Dry run finished; nothing was published"
    mkdir -p "$ROOT/build/release"
    cp "$ZIP" "$CASK" "$ROOT/build/release/"
    echo "App:  $ROOT/build/release/$(basename "$ZIP")"
    echo "Cask: $ROOT/build/release/$(basename "$CASK")"
    echo
    cat "$CASK"
    exit 0
fi

# MARK: - Publish

step "Committing and tagging $TAG"
git add "$PROJECT_FILE" "$GLOBALS_FILE"
git commit -q -m "Release $VERSION"
RESTORE_VERSION=false
git tag -a "$TAG" -m "MacDown $VERSION"
git push -q origin main "$TAG"

step "Creating the GitHub release"
gh release create "$TAG" "$ZIP" --repo "$GITHUB_REPO" \
    --title "MacDown $VERSION" --generate-notes

step "Updating $TAP_REPO"
gh repo clone "$TAP_REPO" "$WORK/tap" -- -q
mkdir -p "$WORK/tap/Casks"
cp "$CASK" "$WORK/tap/Casks/$CASK_NAME.rb"
git -C "$WORK/tap" add "Casks/$CASK_NAME.rb"
git -C "$WORK/tap" \
    -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
    commit -q -m "$CASK_NAME $VERSION"
git -C "$WORK/tap" push -q

TAP_NAME="${TAP_REPO%%/*}/${TAP_REPO#*/homebrew-}"
# Homebrew only checks casks inside a tap.
if command -v brew >/dev/null && brew tap | grep -qx "$TAP_NAME"; then
    step "Auditing the cask"
    brew update --quiet
    brew style --cask "$TAP_NAME/$CASK_NAME"
    brew audit --cask --strict --online "$TAP_NAME/$CASK_NAME"
fi

step "Released MacDown $VERSION"
echo "Install with: brew install --cask $TAP_NAME/$CASK_NAME"
brew tap | grep -qx "$TAP_NAME" 2>/dev/null \
    || echo "Check the cask with: brew tap $TAP_NAME && brew audit --cask --strict --online $TAP_NAME/$CASK_NAME"
