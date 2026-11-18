#!/usr/bin/env bash
# Signs the app of an archive ad hoc with the entitlements file of its target.
# Then checks that the signature holds every entitlement key of that file.
#
# The TestFlight workflow archives with signing off. An unsigned bundle holds no entitlements, and the export takes
# the entitlements from the signatures in the archive. Without this step the exported build would lack them. The
# export then signs again with the distribution certificate and keeps these entitlements.
# Version 1 of the app declares no entitlement yet.
# Phase 7 adds the App Group, the keychain access group, push and App Attest to App/Lastide.entitlements.
# Phase 7 also adds the notification service extension and the widget to BUNDLES below, inner bundles first.
# Usage: sign_with_entitlements.sh ARCHIVE.xcarchive
set -euo pipefail
archive="$1"
app="$archive/Products/Applications/Lastide.app"
test -d "$app"
# Each line: a bundle path inside the archive, then its entitlements file. Inner bundles come first, because the
# signature of the app covers the signatures inside it.
BUNDLES=(
  "$app|App/Lastide.entitlements"
)
for entry in "${BUNDLES[@]}"; do
  bundle="${entry%%|*}"
  entitlements="${entry#*|}"
  test -d "$bundle"
  test -f "$entitlements"
  codesign --force --sign - --entitlements "$entitlements" "$bundle"
  signed="$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)"
  keys="$(plutil -convert json -o - "$entitlements" | python3 -c 'import json, sys; print(chr(10).join(sorted(json.load(sys.stdin))))')"
  for key in $keys; do
    if ! printf '%s' "$signed" | grep -q "<key>$key</key>"; then
      echo "error: the signature of $(basename "$bundle") lacks the entitlement $key" >&2
      exit 1
    fi
  done
  echo "signed $(basename "$bundle") with $(printf '%s\n' "$keys" | grep -c . || true) entitlement keys from $entitlements"
done
