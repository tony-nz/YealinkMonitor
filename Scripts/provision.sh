#!/usr/bin/env bash
#
# Provisions YealinkMonitor on a Mac: stores the client secret in the login
# keychain and the Client ID and region in the app's preferences, so the app is
# ready to run without anyone typing credentials into Settings.
#
# The secret is never embedded in the .app. That matters more than it might
# look: the YMCS AccessKey authorises device restart, factory reset, firmware
# push and configuration push across the whole enterprise, and YMCS issues one
# pair per enterprise, so it cannot be scoped down or rotated for this app
# alone. A copy of a bundle with the key baked in is a copy of that capability.
#
# Usage:
#   ./Scripts/provision.sh --id <ACCESS_KEY_ID> [--region au|eu|us] [--app /path/to/YealinkMonitor.app]
#
# Passing --app also clears the app's quarantine flag, which is what stops an
# ad-hoc signed bundle opening on a Mac it was copied to.
#   ./Scripts/provision.sh --uninstall
#
# The secret is prompted for, or read from YMCS_CLIENT_SECRET. It is never
# passed as an argument, because command lines are visible to every process on
# the machine via ps.

set -uo pipefail

# Overridable so the script can be exercised without touching real credentials.
SERVICE="${YM_KEYCHAIN_SERVICE:-nz.co.myers.YealinkMonitor}"
ACCOUNT="ymcs-client-secret"
DOMAIN="${YM_DEFAULTS_DOMAIN:-nz.co.myers.YealinkMonitor}"

CLIENT_ID=""
REGION="au"
APP_PATH=""
ALLOW_ANY=0
UNINSTALL=0

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)        CLIENT_ID="${2:-}"; shift 2 ;;
        --region)    REGION="${2:-}"; shift 2 ;;
        --app)       APP_PATH="${2:-}"; shift 2 ;;
        --allow-any) ALLOW_ANY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)   usage 0 ;;
        *) echo "error: unknown option $1" >&2; usage 64 ;;
    esac
done

if [[ $UNINSTALL -eq 1 ]]; then
    security delete-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1 \
        && echo "Removed the keychain item." \
        || echo "No keychain item to remove."
    defaults delete "$DOMAIN" >/dev/null 2>&1 \
        && echo "Removed preferences for $DOMAIN." \
        || echo "No preferences to remove."
    exit 0
fi

[[ -n "$CLIENT_ID" ]] || { echo "error: --id is required" >&2; usage 64; }

case "$REGION" in
    au|eu|us) ;;
    *) echo "error: --region must be au, eu or us (got '$REGION')" >&2; exit 64 ;;
esac

# Checked here rather than further down, where it is needed: everything below
# prompts for the secret first, and being told the path is wrong *after* typing
# a credential means typing it again for no reason.
if [[ -n "$APP_PATH" && ! -d "$APP_PATH" ]]; then
    echo "error: no app bundle at $APP_PATH" >&2
    # A near miss is the usual cause -- "builds/" for "build/", or a path
    # relative to the wrong directory -- so name the bundles that do exist.
    found=0
    for candidate in \
        "$(dirname "${BASH_SOURCE[0]}")/../build/YealinkMonitor.app" \
        "/Applications/YealinkMonitor.app"
    do
        [[ -d "$candidate" ]] || continue
        if [[ $found -eq 0 ]]; then
            echo "       there is one at:" >&2
            found=1
        fi
        echo "         $(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")" >&2
    done
    exit 66
fi

SECRET="${YMCS_CLIENT_SECRET:-}"
if [[ -z "$SECRET" ]]; then
    printf 'AccessKey Secret (input hidden): ' >&2
    read -rs SECRET
    printf '\n' >&2
fi
[[ -n "$SECRET" ]] || { echo "error: no secret provided" >&2; exit 64; }

# --- keychain ------------------------------------------------------------
# -U updates in place if the item already exists, rather than failing.
# Expanded with the ${x[@]+...} guard below: macOS ships bash 3.2, where an
# empty array expansion trips `set -u`.
declare -a TRUST_ARGS=()
if [[ $ALLOW_ANY -eq 1 ]]; then
    # No prompt ever, but any process running as this user can read the secret.
    TRUST_ARGS=(-A)
elif [[ -n "$APP_PATH" ]]; then
    # Already validated above, before the secret was asked for.
    TRUST_ARGS=(-T "$APP_PATH/Contents/MacOS/YealinkMonitor")
fi

if ! security add-generic-password \
        -U -s "$SERVICE" -a "$ACCOUNT" -w "$SECRET" \
        -D "application password" \
        -j "YMCS AccessKey Secret for YealinkMonitor" \
        ${TRUST_ARGS[@]+"${TRUST_ARGS[@]}"} 2>/dev/null; then
    echo "error: could not write the keychain item" >&2
    exit 70
fi
unset SECRET
echo "Stored the secret in the login keychain ($SERVICE)."

# --- preferences ---------------------------------------------------------
defaults write "$DOMAIN" clientID -string "$CLIENT_ID"
defaults write "$DOMAIN" region -string "$REGION"
echo "Wrote Client ID and region ($REGION) to $DOMAIN."

# --- quarantine ----------------------------------------------------------
# The bundle is only ad-hoc signed, so a copy that arrived by any route which
# sets the quarantine flag -- AirDrop, email, a download, a sync folder -- is
# refused by Gatekeeper. On macOS 15 that shows as "the application is damaged
# and can't be opened", with no right-click bypass, which reads like a broken
# download rather than a signing policy.
#
# This script already runs on the target Mac and already knows where the app
# is, so it clears the flag rather than leaving it as a step to find out about
# the hard way.
if [[ -n "$APP_PATH" && -d "$APP_PATH" ]]; then
    if xattr -d -r com.apple.quarantine "$APP_PATH" 2>/dev/null; then
        echo "Cleared the quarantine flag on $APP_PATH."
    else
        echo "No quarantine flag on $APP_PATH."
    fi
fi

cat <<NOTE

Done. Launch YealinkMonitor and it should connect without any setup.

NOTE

if [[ $ALLOW_ANY -eq 0 ]]; then
    cat <<'NOTE'
On first launch macOS will ask whether YealinkMonitor may use the keychain
item. Click "Always Allow".

That prompt returns whenever the app is rebuilt, because ad-hoc signatures
differ on every build and macOS ties keychain access to code identity. A
Developer ID signature fixes it permanently; --allow-any avoids it at the cost
of letting any process running as this user read the secret.
NOTE
fi
