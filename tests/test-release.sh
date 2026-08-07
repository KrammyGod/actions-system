#!/usr/bin/env bash
# Behaviour of the release glue, against a real local remote.
#
# git push is NOT stubbed — the repo pushes to a bare clone on disk, so tag
# creation and the force-move of the major alias are exercised for real. Only
# `gh` is stubbed, since it is the one thing that needs GitHub.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.github/release/release.sh"

make_repo() {
    d=$(mktemp -d)
    git init --quiet --bare "$d/remote.git"
    git init --quiet -b main "$d/work"
    mkdir -p "$d/bin"
    cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
STUB
    chmod +x "$d/bin/gh"
    (
        cd "$d/work" || exit 1
        git config user.email t@t; git config user.name t
        git remote add origin "$d/remote.git"
        git commit --quiet --allow-empty -m "chore: initial"
        git push --quiet -u origin main
    )
    printf '%s' "$d"
}

commit() { git -C "$1/work" commit --quiet --allow-empty -m "$2"; }

release() { # <dir> [bump]
    ( cd "$1/work" && PATH="$1/bin:$PATH" GH_LOG="$1/gh.log" BUMP="${2:-auto}" \
        bash "$SCRIPT" 2>&1 )
}

tags_on_remote() { git -C "$1/remote.git" tag --list | sort | tr '\n' ' '; }
alias_points_at() { git -C "$1/remote.git" rev-list -n1 "$2" 2>/dev/null; }

# --- first release ----------------------------------------------------------
D=$(make_repo)
out=$(release "$D")
# `sort` puts the alias before the release it points at: v1 sorts before v1.0.0.
assert_eq "the first release is v1.0.0" "v1 v1.0.0 " "$(tags_on_remote "$D")"
assert_match "the alias is reported alongside the version" 'v1\.0\.0 \(alias v1\)' "$out"
assert_match "a GitHub release is published" 'release create v1\.0\.0' "$(cat "$D/gh.log")"

# The whole point of the alias: consumers pin @v1 and must receive this.
assert_eq "v1 points at the same commit as v1.0.0" \
    "$(alias_points_at "$D" v1.0.0)" "$(alias_points_at "$D" v1)"

# --- a feat moves the alias -------------------------------------------------
commit "$D" "feat: add an input"
out=$(release "$D")
assert_eq "a feat releases a minor" "v1 v1.0.0 v1.1.0 " "$(tags_on_remote "$D")"
assert_eq "and the alias follows it" \
    "$(alias_points_at "$D" v1.1.0)" "$(alias_points_at "$D" v1)"
assert_ne "so the alias no longer points at the old release" \
    "$(alias_points_at "$D" v1.0.0)" "$(alias_points_at "$D" v1)"

# --- nothing releasable -----------------------------------------------------
: > "$D/gh.log"
commit "$D" "docs: expand the README"
out=$(release "$D")
assert_eq "a docs-only push tags nothing" "v1 v1.0.0 v1.1.0 " "$(tags_on_remote "$D")"
assert_match "and says so" 'nothing since v1\.1\.0 warrants a release' "$out"
assert_eq "and publishes no release" "" "$(cat "$D/gh.log")"

# --- a breaking change cuts a new alias ------------------------------------
commit "$D" "feat!: require namespace"
release "$D" >/dev/null
assert_eq "a breaking change releases v2.0.0" "v1 v1.0.0 v1.1.0 v2 v2.0.0 " \
    "$(tags_on_remote "$D")"
# This is what makes a major bump safe: existing consumers keep working.
assert_eq "v1 is left frozen at the last v1.x.x" \
    "$(alias_points_at "$D" v1.1.0)" "$(alias_points_at "$D" v1)"
assert_eq "and v2 is a separate alias" \
    "$(alias_points_at "$D" v2.0.0)" "$(alias_points_at "$D" v2)"

# --- bootstrapping over a hand-made alias -----------------------------------
# The repo was released manually as `v1` before any of this existed. `v1` is
# alias-shaped, not vX.Y.Z, so it must not be mistaken for the latest release —
# reading it as one would fail the semver parse and break the first run.
D2=$(make_repo)
git -C "$D2/work" tag v1
git -C "$D2/work" push --quiet origin v1
out=$(release "$D2")
assert_eq "a pre-existing v1 alias does not count as a release" "v1 v1.0.0 " \
    "$(tags_on_remote "$D2")"
assert_eq "and the alias is moved onto the first real release" \
    "$(alias_points_at "$D2" v1.0.0)" "$(alias_points_at "$D2" v1)"
rm -rf "$D2"

# --- forced bump ------------------------------------------------------------
commit "$D" "docs: still nothing"
release "$D" patch >/dev/null
assert_eq "a forced bump releases what auto would skip" "v2.0.1" \
    "$(git -C "$D/remote.git" tag --list 'v2.0.1')"
rm -rf "$D"

finish
