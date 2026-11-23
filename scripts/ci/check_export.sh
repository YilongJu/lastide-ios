#!/usr/bin/env bash
# Checks the entitlements and build numbers of the three bundles in an exported .ipa (design section 6.9).
#
# Each bundle must carry exactly the keys of design Table 13, with these values:
#   Lastide.app                 aps-environment production; App Attest environment production or development;
#                               the App Group; the keychain group <team>.dev.lastide.app.shared
#   LastideNotifications.appex  the App Group; the keychain group
#   LastideWidget.appex         aps-environment production; the App Group
# Apple's signing may add four keys, and the check accepts them with these values only:
#   application-identifier <team>.<bundle id>, com.apple.developer.team-identifier <team>,
#   beta-reports-active true, get-task-allow false.
# Any other key, a missing key or another value fails. The three CFBundleVersion values must be equal.
# Usage: check_export.sh EXPORT.ipa TEAM_ID
set -euo pipefail
ipa="${1:?usage: check_export.sh EXPORT.ipa TEAM_ID}"
team="${2:-}"
if [ -z "$team" ]; then
  echo "error: the Team ID is empty" >&2
  exit 1
fi
if [ ! -f "$ipa" ]; then
  echo "error: $ipa is missing" >&2
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unzip -q "$ipa" -d "$work/unzipped"
app="$work/unzipped/Payload/Lastide.app"
for name in app notifications widget; do
  case "$name" in
    app) bundle="$app" ;;
    notifications) bundle="$app/PlugIns/LastideNotifications.appex" ;;
    widget) bundle="$app/PlugIns/LastideWidget.appex" ;;
  esac
  if [ ! -d "$bundle" ]; then
    echo "error: the export lacks $(basename "$bundle")" >&2
    exit 1
  fi
  codesign -d --entitlements - --xml "$bundle" > "$work/$name.xml" 2>/dev/null || true
  cp "$bundle/Info.plist" "$work/$name.plist"
done

python3 - "$work" "$team" <<'PY'
import plistlib
import sys

work, team = sys.argv[1], sys.argv[2]
group = "group.dev.lastide.app"
keychain = f"{team}.dev.lastide.app.shared"
bundles = {
    "app": ("dev.lastide.app", {
        "aps-environment": lambda v: v == "production",
        "com.apple.developer.devicecheck.appattest-environment": lambda v: v in ("production", "development"),
        "com.apple.security.application-groups": lambda v: v == [group],
        "keychain-access-groups": lambda v: v == [keychain],
    }),
    "notifications": ("dev.lastide.app.notifications", {
        "com.apple.security.application-groups": lambda v: v == [group],
        "keychain-access-groups": lambda v: v == [keychain],
    }),
    "widget": ("dev.lastide.app.widget", {
        "aps-environment": lambda v: v == "production",
        "com.apple.security.application-groups": lambda v: v == [group],
    }),
}

failures = []
builds = {}
for name, (bundle_id, required) in bundles.items():
    raw = open(f"{work}/{name}.xml", "rb").read().strip()
    entitlements = plistlib.loads(raw) if raw else {}
    info = plistlib.load(open(f"{work}/{name}.plist", "rb"))
    builds[name] = info.get("CFBundleVersion")
    if info.get("CFBundleIdentifier") != bundle_id:
        failures.append(f"{name}: the bundle id is not {bundle_id}")
    allowed = dict(required)
    allowed.update({
        "application-identifier": lambda v, b=bundle_id: v == f"{team}.{b}",
        "com.apple.developer.team-identifier": lambda v: v == team,
        "beta-reports-active": lambda v: v is True,
        "get-task-allow": lambda v: v is False,
    })
    for key in required:
        if key not in entitlements:
            failures.append(f"{name}: the entitlement {key} is missing")
    for key, value in entitlements.items():
        check = allowed.get(key)
        if check is None:
            failures.append(f"{name}: the entitlement {key} is not on the list")
        elif not check(value):
            failures.append(f"{name}: the entitlement {key} has another value")
    print(f"{name}: {len(entitlements)} entitlement keys, build {builds[name]}")

if len(set(builds.values())) != 1 or None in builds.values():
    failures.append("the three bundles carry different build numbers")
for failure in failures:
    print(f"error: {failure}", file=sys.stderr)
sys.exit(1 if failures else 0)
PY
echo "the export holds the entitlements of design Table 13"
