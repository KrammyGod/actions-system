#!/usr/bin/env bash
# Runs shellcheck over every script this repo ships.
#
# The wording above matters: a comment beginning "shellcheck ..." is parsed as
# a directive and fails to lint this very file.
#
# The point of moving the action logic out of `run:` blocks and into .sh files
# was to make this possible at all — YAML string bodies are invisible to any
# shell linter.
#
# Uses find rather than `git ls-files` so a script that is written but not yet
# staged is still linted; that is exactly when you want the feedback.
#
# -x follows `. lib/assert.sh` into the sourced file instead of warning SC1091.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck not installed — skipping lint (CI installs it)\n' >&2
    exit 0
fi

rc=0
while IFS= read -r f; do
    printf '  -- %s\n' "$f"
    shellcheck -x "$f" || rc=1
done < <(find .github tests -name '*.sh' | sort)

if [ "$rc" -eq 0 ]; then printf 'shellcheck clean\n'; fi
exit "$rc"
