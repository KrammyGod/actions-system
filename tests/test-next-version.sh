#!/usr/bin/env bash
# Behaviour of the release version calculator.
#
# This decides where @v1 points, so a wrong answer is either a release nobody
# receives or a breaking change delivered to every consumer silently.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.github/release/next-version.sh"

v() { # <latest> <messages...>  -> next version
    latest=$1
    shift
    printf '%s\n' "$@" | bash "$SCRIPT" "$latest"
}

# --- bump selection ---------------------------------------------------------
assert_eq "feat is a minor bump" "v1.3.0" "$(v v1.2.4 'feat: add an input')"
assert_eq "fix is a patch bump" "v1.2.5" "$(v v1.2.4 'fix: guard an empty render')"
assert_eq "perf is a patch bump" "v1.2.5" "$(v v1.2.4 'perf: skip a probe')"
assert_eq "refactor is a patch bump" "v1.2.5" "$(v v1.2.4 'refactor: extract glue')"
# The shipped workflows ARE the product here, so a ci: change is a release.
assert_eq "ci is a patch bump" "v1.2.5" "$(v v1.2.4 'ci: pin the flux CLI')"

assert_eq "docs alone releases nothing" "" "$(v v1.2.4 'docs: expand the README')"
assert_eq "chore alone releases nothing" "" "$(v v1.2.4 'chore: tidy')"
assert_eq "unconventional subjects release nothing" "" "$(v v1.2.4 'wip' 'asdf')"

# --- breaking changes -------------------------------------------------------
assert_eq "feat! is a major bump" "v2.0.0" "$(v v1.2.4 'feat!: rename an input')"
assert_eq "fix! is a major bump" "v2.0.0" "$(v v1.2.4 'fix!: drop a default')"
assert_eq "a scoped bang is a major bump" "v2.0.0" \
    "$(v v1.2.4 'feat(deploy)!: require namespace')"
assert_eq "the BREAKING CHANGE footer is a major bump" "v2.0.0" \
    "$(v v1.2.4 'feat: something' '' 'BREAKING CHANGE: images is now required')"
assert_eq "BREAKING-CHANGE is accepted too" "v2.0.0" \
    "$(v v1.2.4 'fix: x' '' 'BREAKING-CHANGE: y')"

# Minor and patch must not reset the majors below them.
assert_eq "a major bump zeroes minor and patch" "v3.0.0" "$(v v2.9.9 'feat!: x')"
assert_eq "a minor bump zeroes patch only" "v1.3.0" "$(v v1.2.9 'feat: x')"
assert_eq "double digits are not string-compared" "v1.11.0" "$(v v1.10.9 'feat: x')"

# --- highest wins -----------------------------------------------------------
assert_eq "a breaking change outranks a feat" "v2.0.0" \
    "$(v v1.2.4 'feat: a' 'fix: b' 'feat!: c')"
assert_eq "a feat outranks a fix regardless of order" "v1.3.0" \
    "$(v v1.2.4 'fix: a' 'feat: b' 'fix: c')"
assert_eq "a releasable commit among chores still releases" "v1.2.5" \
    "$(v v1.2.4 'chore: a' 'docs: b' 'fix: c')"

# --- first release ----------------------------------------------------------
# Callers pin a major alias, so a 0.x phase would mean pinning @v0 and
# re-pinning later for nothing.
assert_eq "no prior release starts at v1.0.0" "v1.0.0" "$(v '' 'chore: initial')"

# --- forced bumps -----------------------------------------------------------
# The escape hatch for cutting v2 deliberately, or releasing a docs-only fix.
assert_eq "a forced major ignores the messages" "v2.0.0" \
    "$(printf 'docs: x\n' | bash "$SCRIPT" v1.2.4 major)"
assert_eq "a forced patch releases what auto would skip" "v1.2.5" \
    "$(printf 'docs: x\n' | bash "$SCRIPT" v1.2.4 patch)"

# --- guards -----------------------------------------------------------------
assert_fails "a non-semver latest is rejected" \
    bash -c "printf 'feat: x\n' | bash '$SCRIPT' v1"
assert_fails "an unknown bump is rejected" \
    bash -c "printf 'feat: x\n' | bash '$SCRIPT' v1.2.4 huge"

finish
