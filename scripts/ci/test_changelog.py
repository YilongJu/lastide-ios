#!/usr/bin/env python3
"""Tests of changelog.py and testflight_notes.py. Run from the repository root: python3 scripts/ci/test_changelog.py

The push check runs on planted commits in a throwaway repository. The notes script runs against a stand-in App Store
Connect server on 127.0.0.1 with a throwaway P-256 key, and `openssl` checks each token's signature.
"""

import base64
import contextlib
import http.server
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import changelog  # noqa: E402
import testflight_notes  # noqa: E402

SAMPLE = """# Changelog

Intro words.

## Unreleased

- First new thing.
- Second new thing that
  wraps.

## Build 8 (2026-11-24)

- Older thing.
"""


def run(*args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, env=env)


class ParseTests(unittest.TestCase):
    def test_the_repository_file_parses(self):
        _, unreleased, builds = changelog.parse(changelog.read(os.path.join(ROOT, "CHANGELOG.md")))
        self.assertEqual([s.build for s in builds], list(range(builds[0].build, 1, -1)))
        for section in builds:
            self.assertTrue(1 <= len(section.entries) <= 8, f"build {section.build}")

    def test_sample(self):
        _, unreleased, builds = changelog.parse(SAMPLE)
        self.assertEqual(unreleased.items(), ["First new thing.", "Second new thing that wraps."])
        self.assertEqual([(s.build, s.date, s.items()) for s in builds], [(8, "2026-11-24", ["Older thing."])])

    def test_refuses_what_the_app_refuses(self):
        # The same cases as ChangelogTests.testRefusesAMalformedFileWithItsLine in LastideKit.
        cases = [
            ("## Build 8 (2026-11-24)\n- One.\n## Build 8 (2026-11-24)\n- Two.\n", 3, "newer"),
            ("## Build 7 (2026-11-24)\n- One.\n## Build 8 (2026-11-24)\n- Two.\n", 3, "newer"),
            ("## Build 8 (24 Nov)\n- One.\n", 1, "date"),
            ("## Build 0 (2026-11-24)\n- One.\n", 1, "heading"),
            ("## Build 8 (2026-13-24)\n- One.\n", 1, "date"),
            ("## Build 8 (2026-11-24)\n", 1, "no entry"),
            ("## Build 8 (2026-11-24)\n- One.\n## Unreleased\n- Two.\n", 3, "first"),
            ("## Unreleased\n- One.\n## Unreleased\n- Two.\n", 3, "first"),
            ("## Build 8 (2026-11-24)\nloose words\n", 2, "line"),
            ("## Build 8 (2026-11-24)\n  wraps with no entry\n", 2, "line"),
            ("## Build 8 (2026-11-24)\n-\n", 2, "empty"),
            ("## Release notes\n- One.\n", 1, "heading"),
            ("# Changelog\n", 1, "no section"),
            ("", 1, "no section"),
        ]
        for text, line, reason in cases:
            with self.subTest(text=text):
                with self.assertRaises(changelog.ChangelogError) as caught:
                    changelog.parse(text)
                self.assertEqual(caught.exception.line, line)
                self.assertIn(reason, caught.exception.reason)


class NotesAndStampTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        self.path = os.path.join(self.folder, "CHANGELOG.md")
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(SAMPLE)

    def test_notes_are_the_unreleased_entries(self):
        self.assertEqual(changelog.notes(self.path, 9), "- First new thing.\n- Second new thing that wraps.\n")

    def test_notes_refuse_an_old_build_and_an_empty_section(self):
        with self.assertRaises(SystemExit):
            changelog.notes(self.path, 8)
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write("## Unreleased\n\n## Build 8 (2026-11-24)\n\n- Older thing.\n")
        with self.assertRaises(SystemExit):
            changelog.notes(self.path, 9)

    def test_stamp_turns_unreleased_into_the_build(self):
        changelog.stamp(self.path, 9, "2026-11-25", changelog.notes(self.path, 9))
        text = changelog.read(self.path)
        self.assertEqual(text, """# Changelog

Intro words.

## Unreleased

## Build 9 (2026-11-25)

- First new thing.
- Second new thing that
  wraps.

## Build 8 (2026-11-24)

- Older thing.
""")
        _, unreleased, builds = changelog.parse(text)
        self.assertEqual(unreleased.items(), [])
        self.assertEqual([s.build for s in builds], [9, 8])

    def test_stamp_keeps_entries_added_after_the_build(self):
        notes = changelog.notes(self.path, 9)
        text = changelog.read(self.path).replace("- First new thing.\n", "- Newer thing.\n- First new thing.\n")
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(text)
        changelog.stamp(self.path, 9, "2026-11-25", notes)
        _, unreleased, builds = changelog.parse(changelog.read(self.path))
        self.assertEqual(unreleased.items(), ["Newer thing."])
        self.assertEqual(builds[0].items(), ["First new thing.", "Second new thing that wraps."])

    def test_stamp_refuses_a_note_that_left_unreleased(self):
        with self.assertRaises(SystemExit):
            changelog.stamp(self.path, 9, "2026-11-25", "- A note nobody wrote.\n")
        self.assertEqual(changelog.read(self.path), SAMPLE, "a refused stamp changed the file")


class PushCheckTests(unittest.TestCase):
    """Planted pushes: each must pass or fail as the rule says."""

    def setUp(self):
        self.repo = tempfile.mkdtemp()
        for args in (["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test"],
                     ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", os.devnull]):
            run("git", *args, cwd=self.repo).check_returncode()
        self.commit({"CHANGELOG.md": SAMPLE, "App/A.swift": "a", "docs/x.md": "x"}, "Start")

    def commit(self, files, message):
        for name, text in files.items():
            path = os.path.join(self.repo, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(text)
        run("git", "add", "-A", cwd=self.repo).check_returncode()
        run("git", "commit", "-q", "-m", message, cwd=self.repo).check_returncode()
        return run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()

    def check(self, base, head):
        result = run(sys.executable, os.path.join(HERE, "changelog.py"), "check-push", "--base", base, "--head", head,
                     cwd=self.repo)
        return result.returncode, result.stdout + result.stderr

    def test_planted_pushes(self):
        start = run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()
        cases = [
            ({"App/A.swift": "b"}, "Change the app", False),
            ({"Extensions/Widget/W.swift": "w"}, "Change the widget", False),
            ({"Packages/LastideKit/Sources/LastideKit/K.swift": "k"}, "Change the package", False),
            ({"App/A.swift": "c", "CHANGELOG.md": ""}, "Change the app", None),
            ({"App/A.swift": "d"}, "Change the app\n\nA rename only. [no changelog]", True),
            ({"docs/x.md": "y"}, "Change a document", True),
            ({"Packages/LastideKit/Tests/T.swift": "t"}, "Change a test", True),
        ]
        for files, message, passes in cases:
            with self.subTest(message=message, files=list(files)):
                base = run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()
                if passes is None:
                    # The changelog gains an entry beside the app change.
                    text = changelog.read(os.path.join(self.repo, "CHANGELOG.md")).replace(
                        "- First new thing.\n", "- First new thing.\n- A planted entry.\n")
                    with open(os.path.join(self.repo, "CHANGELOG.md"), "w", encoding="utf-8") as handle:
                        handle.write(text)
                    files = {k: v for k, v in files.items() if k != "CHANGELOG.md"}
                    passes = True
                head = self.commit(files, message)
                code, output = self.check(base, head)
                self.assertEqual(code == 0, passes, output)
                if not passes:
                    self.assertIn("without changing CHANGELOG.md", output)
                    self.assertIn("[no changelog]", output)
        # A push of several commits passes when one of them carries the mark.
        self.commit({"App/A.swift": "e"}, "One")
        head = self.commit({"App/A.swift": "f"}, "Two [no changelog]")
        self.assertEqual(self.check("HEAD~2", head)[0], 0)
        # The all-zero base of a new branch compares the head commit with its parent.
        head = self.commit({"App/A.swift": "g"}, "Three")
        self.assertNotEqual(self.check("0" * 40, head)[0], 0)
        # The whole range holds the commit that changed CHANGELOG.md, so it passes.
        self.assertEqual(self.check(start, head)[0], 0)


class Handler(http.server.BaseHTTPRequestHandler):
    """A stand-in for the App Store Connect endpoints the notes script calls."""

    def log_message(self, *args):
        pass

    def answer(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        server = self.server
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        server.calls.append((self.command, self.path, body, self.headers.get("Authorization")))
        path = self.path.split("?")[0]
        if path == "/v1/apps":
            return self.answer(200, {"data": [{"type": "apps", "id": "APP1"}]})
        if path == "/v1/builds":
            state = server.states.pop(0) if len(server.states) > 1 else server.states[0]
            data = [] if state is None else [{"type": "builds", "id": "B9", "attributes": {"version": "9", "processingState": state}}]
            return self.answer(200, {"data": data})
        if path == "/v1/builds/B9/betaBuildLocalizations":
            return self.answer(200, {"data": [{"type": "betaBuildLocalizations", "id": lid, "attributes": attrs}
                                              for lid, attrs in server.localizations.items()]})
        if path == "/v1/betaBuildLocalizations" and self.command == "POST":
            attrs = body["data"]["attributes"]
            server.localizations["L1"] = {"locale": attrs["locale"], "whatsNew": attrs["whatsNew"]}
            return self.answer(201, {"data": {"id": "L1"}})
        if path.startswith("/v1/betaBuildLocalizations/") and self.command == "PATCH":
            lid = path.rsplit("/", 1)[1]
            server.localizations[lid]["whatsNew"] = body["data"]["attributes"]["whatsNew"]
            return self.answer(200, {"data": {"id": lid}})
        return self.answer(404, {"errors": [{"detail": "no such path"}]})

    do_GET = do_POST = do_PATCH = handle_any


class NotesScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.mkdtemp()
        cls.key = os.path.join(cls.folder, "AuthKey_TEST.p8")
        ec = run("openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", os.path.join(cls.folder, "ec.pem"),
                 cwd=cls.folder)
        ec.check_returncode()
        run("openssl", "pkcs8", "-topk8", "-nocrypt", "-in", "ec.pem", "-out", cls.key, cwd=cls.folder).check_returncode()
        run("openssl", "ec", "-in", "ec.pem", "-pubout", "-out", "pub.pem", cwd=cls.folder).check_returncode()

    def serve(self, states, localizations=None):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.calls, server.states, server.localizations = [], list(states), dict(localizations or {})
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        api = testflight_notes.Api(f"http://127.0.0.1:{server.server_address[1]}", "TESTKEY", "issuer-1", self.key)
        return server, api

    def verify(self, jwt):
        header, payload, signature = jwt.split(".")
        raw = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
        self.assertEqual(len(raw), 64)

        def integer(part):
            part = part.lstrip(b"\x00") or b"\x00"
            if part[0] & 0x80:
                part = b"\x00" + part
            return b"\x02" + bytes([len(part)]) + part

        body = integer(raw[:32]) + integer(raw[32:])
        sig_path = os.path.join(self.folder, "sig.der")
        with open(sig_path, "wb") as handle:
            handle.write(b"\x30" + bytes([len(body)]) + body)
        check = subprocess.run(["openssl", "dgst", "-sha256", "-verify", "pub.pem", "-signature", "sig.der"],
                               input=f"{header}.{payload}".encode(), cwd=self.folder, capture_output=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        self.assertEqual(claims["aud"], "appstoreconnect-v1")
        self.assertEqual(claims["iss"], "issuer-1")
        self.assertLessEqual(claims["exp"] - claims["iat"], 1200)
        self.assertEqual(json.loads(base64.urlsafe_b64decode(header + "=" * (-len(header) % 4)))["kid"], "TESTKEY")

    def test_tokens_verify(self):
        for _ in range(5):
            self.verify(testflight_notes.token("TESTKEY", "issuer-1", self.key))

    def test_waits_for_processing_then_creates_the_localization(self):
        server, api = self.serve([None, "PROCESSING", "VALID"])
        testflight_notes.set_notes(api, "dev.lastide.app", 9, "- One.\n- Two.", 60, 0, log=lambda _: None)
        self.assertEqual(server.localizations, {"L1": {"locale": "en-US", "whatsNew": "- One.\n- Two."}})
        posts = [call for call in server.calls if call[0] == "POST"]
        self.assertEqual(posts[0][2]["data"]["relationships"]["build"]["data"]["id"], "B9")
        for call in server.calls:
            self.verify(call[3].split(" ", 1)[1])

    def test_updates_an_existing_localization(self):
        server, api = self.serve(["VALID"], {"L7": {"locale": "en-US", "whatsNew": "old"}})
        testflight_notes.set_notes(api, "dev.lastide.app", 9, "- New.", 60, 0, log=lambda _: None)
        self.assertEqual(server.localizations["L7"]["whatsNew"], "- New.")
        self.assertEqual([c[0] for c in server.calls if c[0] in ("POST", "PATCH")], ["PATCH"])

    def test_fails_loudly_on_a_failed_build_and_at_the_time_limit(self):
        server, api = self.serve(["FAILED"])
        with self.assertRaises(SystemExit) as caught:
            testflight_notes.set_notes(api, "dev.lastide.app", 9, "- New.", 60, 0, log=lambda _: None)
        self.assertIn("FAILED", str(caught.exception))
        server, api = self.serve(["PROCESSING"])
        with self.assertRaises(SystemExit) as caught:
            testflight_notes.set_notes(api, "dev.lastide.app", 9, "- New.", 0, 0, log=lambda _: None)
        self.assertIn("still PROCESSING", str(caught.exception))
        self.assertEqual(server.localizations, {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
