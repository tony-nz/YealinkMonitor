#!/usr/bin/env bash
#
# Builds, signs, notarizes and staples a release bundle, then optionally
# publishes it to GitHub.
#
#   ./Scripts/release.sh 0.1.0              # build + notarize, no publish
#   ./Scripts/release.sh 0.1.0 --publish    # ... and create the GitHub release
#   ./Scripts/release.sh 0.1.0 --skip-notarize   # unsigned dry run, local only
#
# What this fixes. `make-app.sh` ad-hoc signs, which is enough to run the app on
# the Mac that built it and no further: Gatekeeper rejects an ad-hoc bundle that
# arrives with the quarantine flag, and on macOS 15 it does so with the words
# "YealinkMonitor is damaged and can't be opened", which sounds like a corrupt
# download and is not. A notarized bundle simply opens.
#
# ---------------------------------------------------------------------------
# One-time setup on the machine that cuts releases
# ---------------------------------------------------------------------------
#
# 1. A **Developer ID Application** certificate. An "Apple Development"
#    certificate is not the same thing and cannot notarize. Create one at
#    developer.apple.com > Certificates > + > Developer ID Application, download
#    it and double-click to install. On an organisation account only the Account
#    Holder may create it.
#
#    Check it is there:
#        security find-identity -v -p codesigning | grep "Developer ID"
#
# 2. Notary credentials, stored once in the keychain:
#
#        xcrun notarytool store-credentials YealinkMonitor \
#            --apple-id you@example.com \
#            --team-id <team id> \
#            --password <app-specific-password>
#
#    The password is an app-specific password from appleid.apple.com, not the
#    Apple ID password. Override the profile name with NOTARY_PROFILE.
#
#    The Team ID is NOT the value in parentheses in an "Apple Development"
#    certificate's name -- that is the certificate's own id, and notarytool
#    answers a 403 for it. It is the organizational unit of the certificate
#    subject:
#
#        security find-certificate -c "Developer ID Application" -p \
#            | openssl x509 -noout -subject -nameopt multiline \
#            | grep organizationalUnitName
#
# 3. For --publish, an authenticated GitHub CLI: `gh auth login`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION=""
PUBLISH=0
SKIP_NOTARIZE=0
NOTES_FILE=""
DRAFT=0

usage() {
    cat >&2 <<'USAGE'
usage: release.sh <version> [--publish] [--draft] [--notes <file>] [--skip-notarize]

  <version>          e.g. 0.1.0. Tagged as v<version>.
  --publish          create the GitHub release and upload the zip
  --draft            with --publish, create it as a draft
  --notes <file>     release notes markdown; defaults to docs/release-notes/v<version>.md
  --skip-notarize    build and sign only. The result is NOT distributable.
USAGE
    exit 64
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish)       PUBLISH=1 ;;
        --draft)         DRAFT=1 ;;
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --notes)         NOTES_FILE="${2:-}"; shift ;;
        -h|--help)       usage ;;
        -*)              echo "error: unknown option '$1'" >&2; usage ;;
        *)
            [[ -z "$VERSION" ]] || { echo "error: version given twice" >&2; usage; }
            VERSION="$1"
            ;;
    esac
    shift
done

[[ -n "$VERSION" ]] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: version must look like 1.2.3, got '$VERSION'" >&2; exit 64
}

TAG="v$VERSION"
APP="$ROOT/build/YealinkMonitor.app"
DIST="$ROOT/build/dist"
ZIP="$DIST/YealinkMonitor-$VERSION.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-YealinkMonitor}"
BUNDLE_ID="nz.co.myers.YealinkMonitor"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty. Commit or stash first -- a release should" >&2
    echo "       correspond to a commit you can go back to." >&2
    exit 1
fi

if [[ $PUBLISH -eq 1 ]] && git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi

IDENTITY="${SIGN_IDENTITY:-}"
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="$(security find-identity -v -p codesigning \
            | grep "Developer ID Application" \
            | head -1 \
            | sed -E 's/.*"(.*)".*/\1/')"
    fi
    if [[ -z "$IDENTITY" ]]; then
        cat >&2 <<'MISSING'
error: no "Developer ID Application" certificate in the keychain.

  An "Apple Development" certificate is a different thing and cannot be used to
  notarize. Create the right one at:

      developer.apple.com > Certificates, Identifiers & Profiles > Certificates
      > + > Developer ID Application

  Download it, double-click to install, then re-run. On an organisation account
  only the Account Holder can create it.

  To build a signed-but-not-distributable bundle in the meantime:
      ./Scripts/release.sh <version> --skip-notarize
MISSING
        exit 1
    fi
    echo "==> Signing identity: $IDENTITY"

    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        cat >&2 <<MISSING
error: no notary credentials stored under the profile "$NOTARY_PROFILE".

  Store them once:

      xcrun notarytool store-credentials $NOTARY_PROFILE \\
          --apple-id you@example.com \\
          --team-id <your team id> \\
          --password <app-specific password from appleid.apple.com>

MISSING
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

echo "==> Building $TAG"
APP_VERSION="$VERSION" "$ROOT/Scripts/make-app.sh" release

# A release must never carry credentials. `make-app.sh --embed` produces a
# bundle that is itself a secret, and one uploaded to a public release would be
# an enterprise-wide AccessKey handed to anyone who clicks Download.
if /usr/libexec/PlistBuddy -c "Print :YMCSClientSecret" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "error: this bundle has embedded credentials. Refusing to package it." >&2
    echo "       Rebuild without --embed." >&2
    exit 1
fi

echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/YealinkMonitor")"

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    echo "==> Signing with Developer ID"
    # --options runtime is what makes the bundle eligible for notarization.
    # --timestamp is required too: a signature without a secure timestamp is
    # rejected by the notary service.
    codesign --force --deep \
        --sign "$IDENTITY" \
        --identifier "$BUNDLE_ID" \
        --options runtime \
        --timestamp \
        "$APP"
    codesign --verify --strict --verbose=2 "$APP"
fi

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------

rm -rf "$DIST"
mkdir -p "$DIST"
# ditto rather than `zip`: it preserves the bundle's symlinks and extended
# attributes, which a plain zip mangles and the notary service then rejects.
echo "==> Packaging $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ---------------------------------------------------------------------------
# Notarize and staple
# ---------------------------------------------------------------------------

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    echo "==> Submitting to the notary service (this takes a few minutes)"
    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "==> Stapling"
    # Staple the app, not the zip: the ticket has to travel inside the bundle so
    # it is present on a Mac that is offline when the app is first opened.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"

    # Repackage now that the ticket is inside.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> Gatekeeper assessment"
    spctl -a -vvv -t install "$APP"
fi

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "==> $ZIP"
echo "    $(du -h "$ZIP" | awk '{print $1}')  sha256 $SHA"

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------

if [[ $PUBLISH -eq 0 ]]; then
    cat <<NEXT

Not published. To publish this build:

    git tag -a $TAG -m "$TAG"
    git push origin $TAG
    gh release create $TAG "$ZIP" --title "$TAG" --notes-file <notes>

or re-run with --publish.
NEXT
    exit 0
fi

if [[ -z "$NOTES_FILE" ]]; then
    NOTES_FILE="$ROOT/docs/release-notes/$TAG.md"
fi
[[ -f "$NOTES_FILE" ]] || {
    echo "error: no release notes at $NOTES_FILE (pass --notes <file>)" >&2
    exit 1
}

command -v gh >/dev/null || { echo "error: gh is not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated. Run: gh auth login" >&2; exit 1; }

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> Creating the GitHub release"
ARGS=(release create "$TAG" "$ZIP" --title "$TAG" --notes-file "$NOTES_FILE")
[[ $DRAFT -eq 1 ]] && ARGS+=(--draft)
gh "${ARGS[@]}"

echo "==> Published $TAG"
