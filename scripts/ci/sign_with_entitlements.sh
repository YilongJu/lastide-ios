#!/usr/bin/env bash
# Signs the app and its two extensions in an archive ad hoc, each with the entitlements file of its target.
# Then checks that each signature holds every entitlement key of that file.
#
# The TestFlight workflow archives with signing off. An unsigned bundle holds no entitlements, and the export takes
# the entitlements from the signatures in the archive. Without this step the exported build would lack them. The
# export then signs again with the distribution certificate and keeps these entitlements.
#
# The entitlements files write two build settings, which Xcode expands only while it signs (design section 6.9):
#   $(LASTIDE_APS_ENVIRONMENT)  takes LastideAPNsEnvironment of the archived app's Info.plist, which must be production
#   $(AppIdentifierPrefix)      takes APPLE_TEAM_ID followed by a dot
# The script stops when a "$(" stays after the expansion, when APPLE_TEAM_ID is empty, or when a bundle is missing.
# Usage: APPLE_TEAM_ID=<team> sign_with_entitlements.sh ARCHIVE.xcarchive
# Run it from the repository root, because the entitlements paths below are relative to it.
set -euo pipefail
archive="${1:?usage: sign_with_entitlements.sh ARCHIVE.xcarchive}"
team="${APPLE_TEAM_ID:-}"
if [ -z "$team" ]; then
  echo "error: APPLE_TEAM_ID is empty" >&2
  exit 1
fi
if ! printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$'; then
  echo "error: APPLE_TEAM_ID is not 10 capital letters or digits" >&2
  exit 1
fi
app="$archive/Products/Applications/Lastide.app"
if [ ! -d "$app" ]; then
  echo "error: the archive lacks Lastide.app" >&2
  exit 1
fi
environment="$(plutil -extract LastideAPNsEnvironment raw -o - "$app/Info.plist" 2>/dev/null || true)"
if [ "$environment" != "production" ]; then
  echo "error: LastideAPNsEnvironment of the archived app is '$environment', and a TestFlight build needs production" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Each line: a bundle path inside the archive, then its entitlements file. Inner bundles come first, because the
# signature of the app covers the signatures inside it.
BUNDLES=(
  "$app/PlugIns/LastideNotifications.appex|Extensions/Notifications/Notifications.entitlements"
  "$app/PlugIns/LastideWidget.appex|Extensions/Widget/Widget.entitlements"
  "$app|App/Lastide.entitlements"
)
for entry in "${BUNDLES[@]}"; do
  bundle="${entry%%|*}"
  source="${entry#*|}"
  if [ ! -d "$bundle" ]; then
    echo "error: the archive lacks $(basename "$bundle")" >&2
    exit 1
  fi
  if [ ! -f "$source" ]; then
    echo "error: the entitlements file $source is missing" >&2
    exit 1
  fi
  expanded="$work/$(basename "$source")"
  python3 - "$source" "$expanded" "$environment" "$team" <<'PY'
import sys
source, target, environment, team = sys.argv[1:5]
text = open(source, encoding="utf-8").read()
text = text.replace("$(LASTIDE_APS_ENVIRONMENT)", environment).replace("$(AppIdentifierPrefix)", team + ".")
open(target, "w", encoding="utf-8").write(text)
PY
  if grep -q '\$(' "$expanded"; then
    echo "error: $source holds a build setting that this script does not expand" >&2
    exit 1
  fi
  plutil -lint -s "$expanded"
  codesign --force --sign - --entitlements "$expanded" "$bundle"
  signed="$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)"
  keys="$(plutil -convert json -o - "$expanded" | python3 -c 'import json, sys; print(chr(10).join(sorted(json.load(sys.stdin))))')"
  for key in $keys; do
    if ! printf '%s' "$signed" | grep -q "<key>$key</key>"; then
      echo "error: the signature of $(basename "$bundle") lacks the entitlement $key" >&2
      exit 1
    fi
  done
  echo "signed $(basename "$bundle") with $(printf '%s\n' "$keys" | grep -c . || true) entitlement keys from $source"
done
