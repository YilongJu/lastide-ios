# Sourced by pre-push and pre-commit. Finds the private workspace that holds the word list and the
# scanners, and sets $top (this repository's root) and $scanners (the scanner folder).
# This repository is public. It sits inside the private workspace repository, one folder down.
# The hooks fail closed: they refuse when the workspace, its list, its scanners or node is missing.
#
# LASTIDE_SHELL names another workspace folder. The hook accepts it only when LASTIDE_HOOK_TEST is 1,
# which the hook's own test sets, and it then says which folder it reads. A lone LASTIDE_SHELL refuses,
# so a variable left over from a test cannot point a real push at a smaller list.

hook="${hook:?workspace.sh: the hook sets its name first}"
top="$(git rev-parse --show-toplevel)" || { echo "$hook: cannot find the repository root; refused" >&2; exit 1; }
if [ -n "${LASTIDE_SHELL:-}" ]; then
	if [ "${LASTIDE_HOOK_TEST:-}" != "1" ]; then
		echo "$hook: LASTIDE_SHELL is set but LASTIDE_HOOK_TEST is not 1; unset LASTIDE_SHELL; refused" >&2
		exit 1
	fi
	echo "$hook: test mode, the workspace is LASTIDE_SHELL ($LASTIDE_SHELL)" >&2
	shell="$LASTIDE_SHELL"
else
	shell="$top/.."
fi
scanners="$shell/scripts/spinout-ip-audit"

for f in "$scanners/confidential.local.json" "$scanners/prepush-scan.mjs" "$scanners/scan.mjs" "$scanners/patterns.mjs"; do
	if [ ! -f "$f" ]; then
		echo "$hook: the workspace file $(basename "$f") is missing; refused" >&2
		exit 1
	fi
done
command -v node >/dev/null 2>&1 || { echo "$hook: node is not on PATH; refused" >&2; exit 1; }

# Runs the working tree scan of this repository. Prints the scan's summary on a failure, which names
# files and pattern groups and masks every match.
scan_tree() {
	if ! out="$(node "$scanners/scan.mjs" --scopes=tree --repos=lastide-ios 2>&1)"; then
		printf '%s\n' "$out" | grep -v '^wrote ' >&2
		echo "$hook: the working tree scan failed; refused" >&2
		exit 1
	fi
}
