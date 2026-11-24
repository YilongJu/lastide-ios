#!/usr/bin/env bash
# Check U3 of the learning evidence design: the made-up words of the hosted test LearningWordsTests appear in no
# fixture, demo file, app source or screenshot view tree. Each argument is a file or a folder to search.
#
#   check_no_words.sh App Extensions Tests/UITests Packages/LastideKit/Sources build/screenshots
#
# With --plant, the script copies the demo fixtures, writes the words into the copy of learning.json, and passes only
# when the search finds them there. So the search is shown to catch a fixture with words.
set -euo pipefail
root="$(pwd)"
marker="$(sed -n 's/.*static let marker = "\(.*\)"$/\1/p' "$root/Tests/HostedTests/LearningWordsTests.swift")"
if [ -z "$marker" ]; then
  echo "::error::LearningWordsTests.swift names no marker"
  exit 1
fi

search() {
  local found=0
  for path in "$@"; do
    test -e "$path" || { echo "::error::$path does not exist"; return 2; }
    if grep -rlF -- "$marker" "$path"; then found=1; fi
  done
  return "$found"
}

if [ "${1:-}" = "--plant" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  cp -R "$root/Packages/LastideKit/Sources/LastideKit/Resources/Demo" "$work/Demo"
  python3 - "$work/Demo/learning.json" "$marker" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
planted = text.replace('"projectName":"northwind-reports"', '"projectName":"northwind-reports","words":"' + marker + '"', 1)
assert planted != text, 'the plant did not change learning.json'
open(path, 'w', encoding='utf-8').write(planted)
PY
  if search "$work/Demo" > /dev/null; then
    echo "::error::the search did not find the words planted in a copy of learning.json"
    exit 1
  fi
  echo "the search found the words planted in a copy of learning.json"
  exit 0
fi

if [ "$#" -eq 0 ]; then
  echo "usage: check_no_words.sh PATH... | --plant"
  exit 2
fi
if ! search "$@"; then
  echo "::error::the hosted test's words appear in the files listed above"
  exit 1
fi
echo "the hosted test's words appear in none of: $*"
