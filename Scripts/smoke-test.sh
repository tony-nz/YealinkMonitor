#!/usr/bin/env bash
#
# Phase 0 smoke test for the YMCS Open API.
#
# Verifies that a Client ID / Secret can obtain an access token and read the
# device list, and reports which regional host answers. Nothing else in this
# project works until this passes.
#
# Usage:
#   export YMCS_CLIENT_ID=...
#   export YMCS_CLIENT_SECRET=...
#   ./Scripts/smoke-test.sh            # try every region
#   ./Scripts/smoke-test.sh au         # try one region
#
# The secret is read from the environment and never written to disk or logged.

set -uo pipefail

REGIONS=("au" "eu" "us")
if [[ $# -ge 1 ]]; then REGIONS=("$1"); fi

if [[ -z "${YMCS_CLIENT_ID:-}" || -z "${YMCS_CLIENT_SECRET:-}" ]]; then
  cat >&2 <<'USAGE'
error: YMCS_CLIENT_ID and YMCS_CLIENT_SECRET must be set.

Obtain them from the YMCS console (Enterprise Management > API Services).
Note that YMCS issues only ONE pair per enterprise -- check whether another
integration is already using them before generating a new pair, as generating
new credentials may invalidate the old ones.

  export YMCS_CLIENT_ID='...'
  read -rs YMCS_CLIENT_SECRET && export YMCS_CLIENT_SECRET
USAGE
  exit 64
fi

basic_auth() { printf '%s:%s' "$YMCS_CLIENT_ID" "$YMCS_CLIENT_SECRET" | base64 | tr -d '\n'; }
now_ms()     { echo $(( $(date +%s) * 1000 )); }
nonce()      { uuidgen | tr -d '-'; }

# json_get <key> -- read a top-level string/number from JSON on stdin.
json_get() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None: sys.exit(1)
print(v)
' "$1" 2>/dev/null
}

ok=1
for region in "${REGIONS[@]}"; do
  host="${region}-api.ymcs.yealink.com"
  echo
  echo "=== ${host} ==="

  # --- 1. token ---------------------------------------------------------
  body=$(mktemp)
  code=$(curl -sS --max-time 20 -o "$body" -w '%{http_code}' \
    -X POST "https://${host}/v2/token" \
    -H "Authorization: Basic $(basic_auth)" \
    -H "timestamp: $(now_ms)" \
    -H "nonce: $(nonce)" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d 'grant_type=client_credentials' 2>&1)

  if [[ "$code" != "200" ]]; then
    echo "  token   FAIL  HTTP ${code}"
    # Show the server's own explanation; it distinguishes wrong-region from
    # wrong-credentials, which otherwise look identical.
    sed -e 's/^/          /' "$body" | head -5
    rm -f "$body"
    continue
  fi

  token=$(json_get access_token < "$body")
  expires=$(json_get expires_in < "$body")
  rm -f "$body"
  if [[ -z "$token" ]]; then
    echo "  token   FAIL  200 but no access_token in response"
    continue
  fi
  echo "  token   OK    expires_in=${expires}s"

  # --- 2. device list ---------------------------------------------------
  body=$(mktemp)
  code=$(curl -sS --max-time 20 -o "$body" -w '%{http_code}' \
    -X POST "https://${host}/v2/dm/listDevices" \
    -H "Authorization: Bearer ${token}" \
    -H "timestamp: $(now_ms)" \
    -H "nonce: $(nonce)" \
    -H "Content-Type: application/json" \
    -d '{"skip":0,"limit":5,"autoCount":true}' 2>&1)

  if [[ "$code" != "200" ]]; then
    echo "  devices FAIL  HTTP ${code}"
    sed -e 's/^/          /' "$body" | head -5
    rm -f "$body"
    continue
  fi

  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  devices OK    total={d.get(\"total\")}")
for x in d.get("data", [])[:5]:
    print(f"          {x.get(\"deviceStatus\",\"?\"):<8} {x.get(\"mac\",\"\"):<14} {x.get(\"name\",\"\")}")
' "$body"
  rm -f "$body"

  # --- 3. offline count (the polling heartbeat) -------------------------
  offline=$(curl -sS --max-time 20 \
    "https://${host}/v2/dm/statistics/deviceCount?deviceStatus=0" \
    -H "Authorization: Bearer ${token}" \
    -H "timestamp: $(now_ms)" \
    -H "nonce: $(nonce)" | json_get total)
  echo "  offline OK    total=${offline:-?}"

  echo
  echo "SUCCESS: your enterprise is in the '${region}' region."
  echo "Set this in the app's Settings, or export YMCS_REGION=${region}"
  ok=0
  break
done

exit $ok
