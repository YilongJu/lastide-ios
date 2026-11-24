#!/usr/bin/env python3
"""Sets a TestFlight build's "What to Test" text through the App Store Connect API.

  testflight_notes.py --bundle-id dev.lastide.app --build 9 --notes notes.txt --wait-minutes 45

The script finds the app by its bundle id and the build by its build number, waits until App Store Connect has
processed the build, then writes the notes as the build's en-US beta build localization (`whatsNew`) and reads them
back. It fails with the API's answer when any step fails or the build is not processed within the time limit.

It reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file) from the environment and signs each request's token
with `openssl`, so it needs no Python package. `--api-base` exists for the local test against a stand-in server.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

LOCALE = "en-US"
# App Store Connect's limit on whatsNew.
LONGEST_NOTES = 4000


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw(der):
    """An ECDSA signature in DER (SEQUENCE of two INTEGERs) as the 64 bytes r || s that ES256 uses."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("openssl gave no DER signature")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("the DER signature holds no INTEGER")
        length = der[index + 1]
        value = der[index + 2:index + 2 + length].lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("an ES256 signature part is longer than 32 bytes")
        parts.append(value.rjust(32, b"\x00"))
        index += 2 + length
    return parts[0] + parts[1]


def token(key_id, issuer, key_path, now=None):
    """An App Store Connect API token, valid for 15 minutes."""
    now = int(time.time()) if now is None else now
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                                separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                         capture_output=True, check=True).stdout
    return f"{header}.{payload}.{b64url(der_to_raw(der))}"


class Api:
    def __init__(self, base, key_id, issuer, key_path):
        self.base = base.rstrip("/")
        self.key_id, self.issuer, self.key_path = key_id, issuer, key_path

    def call(self, method, path, query=None, body=None):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Authorization", "Bearer " + token(self.key_id, self.issuer, self.key_path))
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                text = response.read().decode()
        except urllib.error.HTTPError as error:
            raise SystemExit(f"error: {method} {path} answered {error.code}: {error.read().decode(errors='replace')}")
        return json.loads(text) if text else {}


def set_notes(api, bundle_id, build_number, notes, wait_seconds, poll_seconds, log=print):
    apps = api.call("GET", "/v1/apps", {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId"})["data"]
    if len(apps) != 1:
        raise SystemExit(f"error: App Store Connect lists {len(apps)} apps with the bundle id {bundle_id}")
    app_id = apps[0]["id"]

    deadline = time.monotonic() + wait_seconds
    while True:
        builds = api.call("GET", "/v1/builds", {"filter[app]": app_id, "filter[version]": str(build_number),
                                                 "fields[builds]": "version,processingState"})["data"]
        if len(builds) > 1:
            raise SystemExit(f"error: App Store Connect lists {len(builds)} builds numbered {build_number}")
        state = builds[0]["attributes"]["processingState"] if builds else "NOT LISTED YET"
        if state == "VALID":
            build_id = builds[0]["id"]
            break
        if state in ("FAILED", "INVALID"):
            raise SystemExit(f"error: App Store Connect marked build {build_number} {state}")
        if time.monotonic() >= deadline:
            raise SystemExit(f"error: build {build_number} was still {state} after {wait_seconds // 60} minutes; "
                             "set its What to Test by hand in App Store Connect")
        log(f"build {build_number}: {state}; next look in {poll_seconds} s")
        time.sleep(poll_seconds)

    found = api.call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations",
                     {"fields[betaBuildLocalizations]": "locale,whatsNew"})["data"]
    mine = [item for item in found if item["attributes"]["locale"] == LOCALE]
    if mine:
        api.call("PATCH", f"/v1/betaBuildLocalizations/{mine[0]['id']}",
                 body={"data": {"type": "betaBuildLocalizations", "id": mine[0]["id"], "attributes": {"whatsNew": notes}}})
    else:
        api.call("POST", "/v1/betaBuildLocalizations", body={"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": LOCALE, "whatsNew": notes},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})

    back = api.call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations",
                    {"fields[betaBuildLocalizations]": "locale,whatsNew"})["data"]
    shown = [item["attributes"].get("whatsNew") for item in back if item["attributes"]["locale"] == LOCALE]
    if shown != [notes]:
        raise SystemExit(f"error: build {build_number}'s {LOCALE} What to Test reads {shown!r} after the write")
    log(f"build {build_number}: What to Test ({LOCALE}) is set, {len(notes)} characters")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--notes", required=True, help="the file that holds the notes")
    parser.add_argument("--wait-minutes", type=int, required=True)
    parser.add_argument("--poll-seconds", type=int, default=30)
    parser.add_argument("--api-base", default="https://api.appstoreconnect.apple.com")
    args = parser.parse_args()
    missing = [name for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not os.environ.get(name)]
    if missing:
        raise SystemExit("error: the environment lacks " + ", ".join(missing))
    with open(args.notes, encoding="utf-8") as handle:
        notes = handle.read().strip()
    if not notes:
        raise SystemExit(f"error: {args.notes} is empty")
    if len(notes) > LONGEST_NOTES:
        raise SystemExit(f"error: the notes hold {len(notes)} characters; App Store Connect takes {LONGEST_NOTES}")
    api = Api(args.api_base, os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_PATH"])
    set_notes(api, args.bundle_id, args.build, notes, args.wait_minutes * 60, args.poll_seconds)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
