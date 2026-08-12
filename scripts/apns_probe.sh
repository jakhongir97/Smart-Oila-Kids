#!/bin/bash
# Send a background push straight to APNs, bypassing Firebase and the backend entirely.
#
# This is the fastest way to answer "is the APNs Auth Key good?" without touching a console. A 200
# means the key, the topic and the device token are all correct. The interesting case is the ERROR:
#   BadDeviceToken               the key is fine; the token belongs to the OTHER environment
#   InvalidProviderToken (403)   the key is not valid for this environment (or the wrong team)
#   BadEnvironmentKeyIdInToken   the key is scoped to one environment and this is the other one
# So probing BOTH hosts with one sandbox token tells you the key's environment scope: sandbox 200 +
# production BadDeviceToken means the key covers both, which is what you want.
#
# The .p8 is passed in by path and is never stored in this repo -- it is a signing credential that
# can push to every app in the team.
#
# usage: apns_probe.sh <path-to-.p8> <key-id> <team-id> <hex-device-token> [sandbox|production]
set -euo pipefail

P8="$1"; KEY_ID="$2"; TEAM_ID="$3"; DEVICE_TOKEN="$4"; ENVIRONMENT="${5:-sandbox}"
TOPIC="uz.smartoila.kids"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -d)/apns_provider_token"

swiftc -O "$ROOT/scripts/apns_provider_token.swift" -o "$BIN"
JWT="$("$BIN" "$P8" "$KEY_ID" "$TEAM_ID")"

case "$ENVIRONMENT" in
  sandbox)    HOST="api.sandbox.push.apple.com" ;;
  production) HOST="api.push.apple.com" ;;
  *) echo "environment must be sandbox or production" >&2; exit 2 ;;
esac

# A wake command, shaped like the one the backend sends. `apns-priority: 5` is mandatory for a
# background push; 10 is rejected. `apns-expiration` keeps APNs from storing a stale command.
curl -s -i --http2 \
  -H "authorization: bearer $JWT" \
  -H "apns-topic: $TOPIC" \
  -H "apns-push-type: background" \
  -H "apns-priority: 5" \
  -H "apns-expiration: $(( $(date +%s) + 120 ))" \
  -d '{"aps":{"content-available":1},"type":"stream.start","mode":"audio","maxDurationSeconds":"120"}' \
  "https://$HOST/3/device/$DEVICE_TOKEN"
