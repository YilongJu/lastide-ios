"""Checks that a device build of the app holds both extensions (design Table 21, check U6).

Usage: python3 check_bundles.py PATH/TO/Lastide.app

Each extension must sit in PlugIns with its bundle id and its extension point id. The script reads the
Info.plist files with plistlib, which reads both the XML and the binary form, so it runs on any system.
"""
import os
import plistlib
import sys

EXPECTED = [
    ("PlugIns/LastideNotifications.appex", "dev.lastide.app.notifications", "com.apple.usernotifications.service"),
    ("PlugIns/LastideWidget.appex", "dev.lastide.app.widget", "com.apple.widgetkit-extension"),
]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_bundles.py PATH/TO/Lastide.app", file=sys.stderr)
        return 2
    app = sys.argv[1]
    failures = []
    for path, bundle_id, point in EXPECTED:
        before = len(failures)
        info_path = os.path.join(app, path, "Info.plist")
        if not os.path.isfile(info_path):
            failures.append(f"{path} is missing")
            continue
        with open(info_path, "rb") as handle:
            info = plistlib.load(handle)
        if info.get("CFBundleIdentifier") != bundle_id:
            failures.append(f"{path}: CFBundleIdentifier is {info.get('CFBundleIdentifier')!r}, not {bundle_id}")
        found = (info.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
        if found != point:
            failures.append(f"{path}: NSExtensionPointIdentifier is {found!r}, not {point}")
        if len(failures) == before:
            print(f"{path}: {bundle_id}, {point}")
    for failure in failures:
        print(f"error: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
