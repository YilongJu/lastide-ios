#!/bin/sh
# Points this repository's hooks at scripts/hooks, so git runs scripts/hooks/pre-commit before every
# commit and scripts/hooks/pre-push before every push. Run it once after a clone, and before any
# remote is added, from Git Bash or any POSIX shell:
#   sh scripts/hooks/install.sh
set -eu
top="$(git rev-parse --show-toplevel)"
cd "$top"
git config core.hooksPath scripts/hooks
for h in pre-commit pre-push; do
	chmod +x "scripts/hooks/$h"
	# Record the executable bit in git too, so a clone on macOS or Linux runs the hook.
	if git ls-files --error-unmatch "scripts/hooks/$h" >/dev/null 2>&1; then
		git update-index --chmod=+x "scripts/hooks/$h"
	fi
done
[ "$(git config core.hooksPath)" = "scripts/hooks" ] || { echo "install.sh: core.hooksPath was not set" >&2; exit 1; }
echo "core.hooksPath is now $(git config core.hooksPath)"
