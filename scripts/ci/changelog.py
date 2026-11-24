#!/usr/bin/env python3
"""CHANGELOG.md for CI: read it, take the next TestFlight build's notes, stamp a build, and check a push.

The format is the one Changelog.parse in LastideKit reads (Packages/LastideKit/Sources/LastideKit/Changelog):

  # Changelog                     optional title, then any lines of introduction
  ## Unreleased                   at most once, and only as the first section
  - An entry.                     "- " starts an entry
    More words of that entry.     two spaces continue the entry above
  ## Build 8 (2026-11-24)         one section per TestFlight build, newest first

Commands:

  changelog.py check [--file F]
      Parses the file and fails on the first line that breaks the format.
  changelog.py notes --build N [--file F]
      Prints the Unreleased entries as "- " lines, the text TestFlight shows as What to Test. Fails when Unreleased is
      empty, or when N is not newer than every build the file lists, because the app then could not call the entries
      build N's own.
  changelog.py stamp --build N --date YYYY-MM-DD --notes NOTES [--file F]
      Moves the entries that NOTES lists out of Unreleased into a new "## Build N (date)" section below it. Entries
      that NOTES does not list stay in Unreleased, so a file that gained entries after the build's commit keeps them.
  changelog.py check-push --base SHA --head SHA
      Fails when the commits change App/, Extensions/ or Packages/LastideKit/Sources/ without changing CHANGELOG.md,
      unless a commit message holds "[no changelog]".
"""

import argparse
import datetime
import re
import subprocess
import sys

APP_PATHS = ("App/", "Extensions/", "Packages/LastideKit/Sources/")
SKIP_MARK = "[no changelog]"
BUILD_HEADING = re.compile(r"^## Build ([1-9][0-9]*) \(([0-9]{4}-[0-9]{2}-[0-9]{2})\)$")


class ChangelogError(Exception):
    def __init__(self, line, reason):
        super().__init__(f"Line {line}: {reason}")
        self.line = line
        self.reason = reason


class Section:
    """A section with its heading line and its entries. Each entry keeps its raw lines, so a stamp moves them as written."""

    def __init__(self, heading_line, build, date):
        self.heading_line = heading_line
        self.build = build
        self.date = date
        self.entries = []  # each: list of raw lines, the first starting with "- "

    def items(self):
        return [entry_text(lines) for lines in self.entries]


def entry_text(lines):
    """An entry's words on one line: its "- " line and the lines that continue it."""
    text = lines[0][1:].strip()
    for more in lines[1:]:
        text += " " + more.strip()
    return text


def parse(text):
    """Returns (preamble lines, unreleased Section or None, build Sections newest first)."""
    lines = text.replace("\r\n", "\n").split("\n")
    preamble = []
    unreleased = None
    builds = []
    current = None
    saw_section = False

    def close():
        if current is None:
            return
        if current.build is not None and not current.entries:
            raise ChangelogError(current.heading_line, f"Build {current.build} has no entry")

    for index, line in enumerate(lines):
        number = index + 1
        if line.startswith("## "):
            close()
            heading = line[3:].strip()
            if heading == "Unreleased":
                if saw_section:
                    raise ChangelogError(number, "Unreleased must be the first section, and only once")
                current = Section(number, None, None)
                unreleased = current
            else:
                match = BUILD_HEADING.match("## " + heading)
                if not match:
                    date_only = re.match(r"^Build ([1-9][0-9]*) \((.*)\)$", heading)
                    if date_only:
                        raise ChangelogError(number, f"the date {date_only.group(2)} is no YYYY-MM-DD date")
                    raise ChangelogError(number, 'a heading reads "## Unreleased" or "## Build N (YYYY-MM-DD)"')
                build, date = int(match.group(1)), match.group(2)
                try:
                    datetime.date.fromisoformat(date)
                except ValueError:
                    raise ChangelogError(number, f"the date {date} is no YYYY-MM-DD date") from None
                if builds and build >= builds[-1].build:
                    raise ChangelogError(
                        number, f"Build {build} must be older than build {builds[-1].build} above it; list newer builds first")
                current = Section(number, build, date)
                builds.append(current)
            saw_section = True
            continue
        if current is None:
            preamble.append(line)
            continue
        if line.strip() == "":
            continue
        if line.startswith("- ") or line == "-":
            if line[1:].strip() == "":
                raise ChangelogError(number, "an entry is empty")
            current.entries.append([line])
        elif line.startswith("  ") and current.entries:
            current.entries[-1].append(line)
        else:
            raise ChangelogError(number, "this line is no heading, no entry and no continued entry")
    close()
    if not saw_section:
        raise ChangelogError(1, 'the file holds no section; a section starts with "## Unreleased" or "## Build N (YYYY-MM-DD)"')
    return preamble, unreleased, builds


def render(preamble, unreleased_entries, builds):
    """Writes the file: the preamble, an Unreleased section (empty or not), then each build."""
    out = list(preamble)
    while out and out[-1] == "":
        out.pop()
    out += ["", "## Unreleased", ""]
    for lines in unreleased_entries:
        out += lines
    if unreleased_entries:
        out.append("")
    for section in builds:
        out += [f"## Build {section.build} ({section.date})", ""]
        for lines in section.entries:
            out += lines
        out.append("")
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out).lstrip("\n") + "\n"


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def notes(path, build):
    _, unreleased, builds = parse(read(path))
    items = unreleased.items() if unreleased else []
    if not items:
        raise SystemExit(f"error: {path} has no entry under \"## Unreleased\". Add the changes of this build there first.")
    if builds and build <= builds[0].build:
        raise SystemExit(f"error: build {build} is not newer than build {builds[0].build}, the newest in {path}.")
    return "".join(f"- {item}\n" for item in items)


def stamp(path, build, date, notes_text):
    datetime.date.fromisoformat(date)
    preamble, unreleased, builds = parse(read(path))
    if builds and build <= builds[0].build:
        raise SystemExit(f"error: build {build} is not newer than build {builds[0].build}, the newest in {path}.")
    wanted = [line[2:] for line in notes_text.split("\n") if line.startswith("- ")]
    if not wanted:
        raise SystemExit("error: the notes hold no entry")
    left = list(unreleased.entries) if unreleased else []
    moved = []
    for item in wanted:
        index = next((i for i, lines in enumerate(left) if entry_text(lines) == item), None)
        if index is None:
            raise SystemExit(f"error: the entry \"{item}\" of the notes is no longer under Unreleased in {path}.")
        moved.append(left.pop(index))
    section = Section(0, build, date)
    section.entries = moved
    text = render(preamble, left, [section] + builds)
    parse(text)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def check_push(base, head):
    if re.fullmatch(r"0+", base or ""):
        base = ""
    if not base:
        parents = git("rev-list", "--parents", "-n", "1", head).split()
        # A first commit compares with the empty tree.
        base = parents[1] if len(parents) > 1 else git("hash-object", "-t", "tree", "--stdin").strip()
        log_range = [head, "-n", "1"]
    else:
        log_range = [f"{base}..{head}"]
    changed = [p for p in git("diff", "--name-only", base, head).split("\n") if p]
    app = [p for p in changed if p.startswith(APP_PATHS)]
    if not app:
        return "no app, extension or LastideKit source changed"
    if "CHANGELOG.md" in changed:
        return "CHANGELOG.md changed with the app"
    messages = git("log", "--format=%B", *log_range)
    if SKIP_MARK in messages:
        return f"a commit message holds {SKIP_MARK}"
    shown = "\n".join(f"  {p}" for p in app[:10]) + ("\n  ..." if len(app) > 10 else "")
    raise SystemExit(
        "error: these commits change the app without changing CHANGELOG.md:\n" + shown + "\n"
        "Add what a tester can now do, or what is fixed, under \"## Unreleased\" in CHANGELOG.md.\n"
        f"When the change means nothing to a tester, write {SKIP_MARK} in a commit message.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check")
    p.add_argument("--file", default="CHANGELOG.md")
    p = sub.add_parser("notes")
    p.add_argument("--file", default="CHANGELOG.md")
    p.add_argument("--build", type=int, required=True)
    p = sub.add_parser("stamp")
    p.add_argument("--file", default="CHANGELOG.md")
    p.add_argument("--build", type=int, required=True)
    p.add_argument("--date", required=True)
    p.add_argument("--notes", required=True)
    p = sub.add_parser("check-push")
    p.add_argument("--base", required=True)
    p.add_argument("--head", required=True)
    args = parser.parse_args()
    try:
        if args.command == "check":
            _, unreleased, builds = parse(read(args.file))
            count = len(unreleased.items()) if unreleased else 0
            print(f"{args.file} reads: {count} unreleased entries, builds {[s.build for s in builds]}")
        elif args.command == "notes":
            sys.stdout.write(notes(args.file, args.build))
        elif args.command == "stamp":
            stamp(args.file, args.build, args.date, read(args.notes))
            print(f"{args.file}: Unreleased became build {args.build} ({args.date})")
        elif args.command == "check-push":
            print("changelog check passed: " + check_push(args.base, args.head))
    except ChangelogError as error:
        raise SystemExit(f"error: {getattr(args, 'file', 'CHANGELOG.md')}: {error}") from None


if __name__ == "__main__":
    main()
