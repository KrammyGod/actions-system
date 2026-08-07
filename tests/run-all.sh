#!/usr/bin/env bash
# Runs every test in this directory. Exits non-zero if any fail.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

rc=0

# Lint first: a shellcheck finding is usually the cheapest explanation for a
# failure below. Skips itself when shellcheck is absent, so this stays runnable
# on a bare checkout.
printf '\n=== tests/lint.sh ===\n'
bash tests/lint.sh || rc=1

for t in tests/test-*.sh; do
    [ -e "$t" ] || continue
    printf '\n=== %s ===\n' "$t"
    bash "$t" || rc=1
done

if [ -f tests/test_workflows.py ]; then
    printf '\n=== tests/test_workflows.py ===\n'
    python tests/test_workflows.py || rc=1
fi

printf '\n'
if [ "$rc" -eq 0 ]; then printf 'ALL SUITES PASSED\n'; else printf 'SUITE FAILURES\n' >&2; fi
exit "$rc"
