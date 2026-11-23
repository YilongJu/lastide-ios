#!/usr/bin/env bash
# Runs the pipeline plants of design section 8.5 on an archive layout made from the unsigned device build.
#
# The script signs the build ad hoc with the made-up Team ID TESTTEAM01, so no Apple account is needed. First the good
# case must pass: sign_with_entitlements.sh, then check_export.sh on an .ipa of the signed app. Then each plant must
# fail, and the script fails when a plant passes:
#   sign_with_entitlements.sh: a planted "$(", an empty APPLE_TEAM_ID, a missing bundle
#   check_export.sh: a widget without aps-environment, a widget with keychain-access-groups, a bundle with an unlisted
#   key, and build numbers that differ
# Usage, from the repository root: run_plants.sh PATH/TO/Release-iphoneos/Lastide.app
set -euo pipefail
device_app="${1:?usage: run_plants.sh PATH/TO/Lastide.app}"
test -d "$device_app"
root="$(pwd)"
team=TESTTEAM01
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed_plants=0
failed_plants=0

make_archive() {
  rm -rf "$1"
  mkdir -p "$1/Products/Applications"
  cp -R "$device_app" "$1/Products/Applications/Lastide.app"
}

make_ipa() {
  rm -rf "$work/ipa" "$2"
  mkdir -p "$work/ipa/Payload"
  cp -R "$1" "$work/ipa/Payload/Lastide.app"
  (cd "$work/ipa" && zip -qry "$2" Payload)
}

# Runs a command that must fail, and records whether it did.
must_fail() {
  local name="$1"
  shift
  if "$@" > "$work/plant.log" 2>&1; then
    echo "::error::the plant '$name' passed, so its check does not catch it"
    sed 's/^/    /' "$work/plant.log"
    passed_plants=$((passed_plants + 1))
  else
    echo "plant '$name' failed as it must: $(grep -m1 'error' "$work/plant.log" || tail -n1 "$work/plant.log")"
    failed_plants=$((failed_plants + 1))
  fi
}

# The good case.
make_archive "$work/good.xcarchive"
APPLE_TEAM_ID="$team" bash scripts/ci/sign_with_entitlements.sh "$work/good.xcarchive"
good_app="$work/good.xcarchive/Products/Applications/Lastide.app"
make_ipa "$good_app" "$work/good.ipa"
bash scripts/ci/check_export.sh "$work/good.ipa" "$team"
for name in app notifications widget; do
  case "$name" in
    app) bundle="$good_app" ;;
    notifications) bundle="$good_app/PlugIns/LastideNotifications.appex" ;;
    widget) bundle="$good_app/PlugIns/LastideWidget.appex" ;;
  esac
  codesign -d --entitlements - --xml "$bundle" > "$work/$name.xml" 2>/dev/null
done

# Plants on sign_with_entitlements.sh.
mkdir -p "$work/repo"
cp -R "$root/App" "$root/Extensions" "$root/scripts" "$work/repo/"
python3 - "$work/repo/Extensions/Widget/Widget.entitlements" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("</dict>", "\t<key>planted</key>\n\t<string>$(UNSET_SETTING)</string>\n</dict>")
open(path, "w", encoding="utf-8").write(text)
PY
make_archive "$work/plant1.xcarchive"
must_fail 'a planted $(' env APPLE_TEAM_ID="$team" bash -c 'cd "$1" && bash scripts/ci/sign_with_entitlements.sh "$2"' \
  _ "$work/repo" "$work/plant1.xcarchive"
make_archive "$work/plant2.xcarchive"
must_fail 'an empty APPLE_TEAM_ID' env APPLE_TEAM_ID= bash scripts/ci/sign_with_entitlements.sh "$work/plant2.xcarchive"
make_archive "$work/plant3.xcarchive"
rm -rf "$work/plant3.xcarchive/Products/Applications/Lastide.app/PlugIns/LastideWidget.appex"
must_fail 'a missing bundle' env APPLE_TEAM_ID="$team" bash scripts/ci/sign_with_entitlements.sh "$work/plant3.xcarchive"

# Plants on check_export.sh. Each one changes a copy of the good app, signs the changed bundle again, and signs the
# app again over it, so each signature stays whole.
plant_export() {
  local name="$1" change="$2"
  rm -rf "$work/plant.app"
  cp -R "$good_app" "$work/plant.app"
  python3 - "$work" "$change" <<'PY'
import plistlib
import sys
work, change = sys.argv[1], sys.argv[2]
def load(name):
    return plistlib.loads(open(f"{work}/{name}.xml", "rb").read())
def save(name, value):
    open(f"{work}/{name}.plant.xml", "wb").write(plistlib.dumps(value))
widget, app = load("widget"), load("app")
if change == "widget-no-aps":
    del widget["aps-environment"]
elif change == "widget-keychain":
    widget["keychain-access-groups"] = app["keychain-access-groups"]
elif change == "app-unlisted":
    app["com.apple.developer.associated-domains"] = ["applinks:example.com"]
save("widget", widget)
save("app", app)
PY
  if [ "$change" = "build-numbers" ]; then
    plutil -replace CFBundleVersion -string 999 "$work/plant.app/PlugIns/LastideWidget.appex/Info.plist"
  fi
  codesign --force --sign - --entitlements "$work/widget.plant.xml" "$work/plant.app/PlugIns/LastideWidget.appex"
  codesign --force --sign - --entitlements "$work/app.plant.xml" "$work/plant.app"
  make_ipa "$work/plant.app" "$work/plant.ipa"
  must_fail "$name" bash scripts/ci/check_export.sh "$work/plant.ipa" "$team"
}
plant_export 'a widget without aps-environment' widget-no-aps
plant_export 'a widget with keychain-access-groups' widget-keychain
plant_export 'a bundle with an unlisted key' app-unlisted
plant_export 'build numbers that differ' build-numbers

echo "plants: $failed_plants failed as they must, $passed_plants passed"
if [ "$passed_plants" -ne 0 ] || [ "$failed_plants" -ne 7 ]; then
  exit 1
fi
