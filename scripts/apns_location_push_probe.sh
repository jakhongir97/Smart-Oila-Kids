#!/bin/bash
# Send a LOCATION push straight to APNs, bypassing Firebase and the backend entirely.
#
# Sibling of apns_probe.sh, for the other push type this app uses. A location push wakes the app's
# Location Push Service Extension (SmartOilaKidsLocationPushExtension) even when the app is not
# running at all -- force-quit, evicted, or simply never opened. The extension takes one fix and
# POSTs it to /device/location/batch itself, so a 200 here means the push was ACCEPTED, not that a
# position arrived; check the parent app, or the child's diagnostics breadcrumbs, for that.
#
# Three things are different from apns_probe.sh and all three are mandatory:
#   apns-topic       <bundle id>.location-query   -- NOT the bare bundle id
#   apns-push-type   location                     -- NOT background
#   device token     the LOCATION-PUSH token      -- NOT the APNs or FCM token
# The location-push token is minted by CoreLocation via startMonitoringLocationPushes and is a third
# address, distinct from both. Sending to the wrong token fails with BadDeviceToken.
#
# Preconditions on the handset, both of which fail silently if unmet:
#   - the child granted "Always" location. Under "While Using" iOS launches nothing.
#   - the build carries com.apple.developer.location.push AND embeds the extension (build 20+).
#
# The .p8 is passed in by path and is never stored in this repo -- it is a signing credential that
# can push to every app in the team.
#
# usage: apns_location_push_probe.sh <path-to-.p8> <key-id> <team-id> <hex-location-push-token> [sandbox|production]
set -euo pipefail

P8="$1"; KEY_ID="$2"; TEAM_ID="$3"; DEVICE_TOKEN="$4"; ENVIRONMENT="${5:-sandbox}"
TOPIC="uz.smartoila.kids.location-query"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -d)/apns_provider_token"

swiftc -O "$ROOT/scripts/apns_provider_token.swift" -o "$BIN"
JWT="$("$BIN" "$P8" "$KEY_ID" "$TEAM_ID")"

case "$ENVIRONMENT" in
  sandbox)    HOST="api.sandbox.push.apple.com" ;;
  production) HOST="api.push.apple.com" ;;
  *) echo "environment must be sandbox or production" >&2; exit 2 ;;
esac

# Priority 10 here, unlike the background push in apns_probe.sh: a location push is a request the
# parent is waiting on, and it is not the throttled background class. The payload body is free-form
# -- the extension reads only its keys, for the diagnostics breadcrumb -- so a correlation id is the
# useful thing to put in it.
curl -s -i --http2 \
  -H "authorization: bearer $JWT" \
  -H "apns-topic: $TOPIC" \
  -H "apns-push-type: location" \
  -H "apns-priority: 10" \
  -H "apns-expiration: $(( $(date +%s) + 120 ))" \
  -d "{\"requestId\":\"probe-$(date +%s)\"}" \
  "https://$HOST/3/device/$DEVICE_TOKEN"
