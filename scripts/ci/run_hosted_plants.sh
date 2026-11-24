#!/usr/bin/env bash
# Shows that checks U2 and K2 of the learning evidence design fail on the faults they guard against. The script plants
# two faults in a copy of AppModel.swift, builds the tests again, and runs each check on its own. Each must fail. It
# then restores the file, so no later step builds the plants.
#
#   K2 plant: a draft's evidence answer drops every reply key, as the code before revision 4 did.
#   U2 plant: the model keeps the words, the pages and the keys when the scene leaves the active state.
#
# Usage, from the repository root, after the simulator build: run_hosted_plants.sh SIMULATOR_UDID
set -euo pipefail
udid="${1:?usage: run_hosted_plants.sh SIMULATOR_UDID}"
model=App/Core/AppModel.swift
backup="$(mktemp)"
cp "$model" "$backup"
trap 'cp "$backup" "$model"; rm -f "$backup"' EXIT

python3 - "$model" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
plants = [
    ('''            open.evidence = words
            evidence = open
        case .learningPage(let page):''', '''            open.evidence = words
            evidence = open
            session?.dropReplyKeys()
        case .learningPage(let page):'''),
    ('''    func sceneLeftActive() {
        evidence = nil
        dropLearning()
        session?.dropReplyKeys()
    }''', '''    func sceneLeftActive() {
    }'''),
]
for old, new in plants:
    assert text.count(old) == 1, 'a plant does not apply: ' + old[:60]
    text = text.replace(old, new)
open(path, 'w', encoding='utf-8').write(text)
PY

xcodebuild build-for-testing -project Lastide.xcodeproj -scheme Lastide \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/sim > build/plants-build.log 2>&1 \
  || { tail -50 build/plants-build.log; echo "::error::the planted build did not compile"; exit 1; }

failed=0
for test in \
  testK2ADraftsEvidenceLeavesTheReplyKeyOfAnOpenLearningRow \
  testU2TheWordsAndTheReplyKeyGoWhenTheSceneLeavesTheActiveState \
  testU2TheDraftScreenDropsItsWordsWhenTheSceneLeavesTheActiveState \
  testU2ListsGoWhenTheSceneLeavesTheActiveState; do
  if xcodebuild test-without-building -project Lastide.xcodeproj -scheme Lastide \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/sim \
      -only-testing:"LastideHostedTests/LearningWordsTests/$test" > "build/plant-$test.log" 2>&1; then
    echo "::error::$test passed on its planted fault, so it does not catch it"
    failed=1
  else
    if grep -q "Executed .* with [1-9][0-9]* failure" "build/plant-$test.log"; then
      echo "$test fails on its planted fault, as it must"
    else
      tail -40 "build/plant-$test.log"
      echo "::error::$test did not run to a test failure on its planted fault"
      failed=1
    fi
  fi
done
exit "$failed"
