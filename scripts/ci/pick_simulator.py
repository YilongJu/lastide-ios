#!/usr/bin/env python3
"""Prints the UDID of the newest iPhone simulator: the newest available iOS runtime first, then the highest
iPhone number on that runtime. A name such as "iPhone 17 Pro" counts as number 17; a plain "iPhone 17" wins a tie.
Stops with an error when no iPhone simulator is available. Usage: pick_simulator.py"""
import json
import re
import subprocess
import sys


def simctl(*args):
    return json.loads(subprocess.run(["xcrun", "simctl", "list", *args, "-j"], check=True, capture_output=True, text=True).stdout)


def version_key(text):
    return tuple(int(part) for part in text.split("."))


runtimes = [r for r in simctl("runtimes", "available")["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: version_key(r["version"]), reverse=True)
devices = simctl("devices", "available")["devices"]
for runtime in runtimes:
    candidates = []
    for device in devices.get(runtime["identifier"], []):
        match = re.match(r"^iPhone (\d+)( .*)?$", device["name"])
        if match and device.get("isAvailable", True):
            candidates.append((int(match.group(1)), match.group(2) is None, device["name"], device["udid"]))
    if candidates:
        candidates.sort(reverse=True)
        number, plain, name, udid = candidates[0]
        print(f"picked {name} on {runtime['name']} ({udid})", file=sys.stderr)
        print(udid)
        sys.exit(0)
sys.exit("no available iPhone simulator on any iOS runtime")
