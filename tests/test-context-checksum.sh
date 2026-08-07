#!/usr/bin/env bash
# Behaviour of the content checksum. The guarantees under test are the ones
# the tag depends on: same content -> same tag, and only files that actually
# enter the build context affect it.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.github/actions/checksum/context-checksum.sh"

# A repo with two build contexts: root (with a .dockerignore) and a nested one.
make_fixture() {
    d=$(mktemp -d)
    (
        cd "$d" || exit 1
        git init -q
        git config user.email t@example.com
        git config user.name tester
        mkdir -p packages/worker node_modules
        printf 'FROM scratch\n'      > Dockerfile
        printf 'app v1\n'            > app.js
        printf 'junk\n'              > node_modules/x.js
        printf 'node_modules\n'      > .dockerignore
        printf 'FROM scratch\n'      > packages/worker/Dockerfile
        printf 'rec v1\n'            > packages/worker/main.go
        git add -A
        git commit -qm init
    )
    printf '%s' "$d"
}

commit_change() { # <dir> <file> <content>
    ( cd "$1" || exit 1; printf '%s\n' "$3" > "$2"; git add -A; git commit -qm change )
}

FIX=$(make_fixture)
root_1=$( cd "$FIX" && bash "$SCRIPT" . Dockerfile )
rec_1=$(  cd "$FIX" && bash "$SCRIPT" packages/worker packages/worker/Dockerfile )

assert_match "tag format is src-<12 hex>" '^src-[0-9a-f]{12}$' "$root_1"

root_again=$( cd "$FIX" && bash "$SCRIPT" . Dockerfile )
assert_eq "same content yields same tag" "$root_1" "$root_again"

assert_ne "different contexts yield different tags" "$root_1" "$rec_1"

# A file inside the root context changes the root tag but not the nested one.
commit_change "$FIX" app.js "app v2"
root_2=$( cd "$FIX" && bash "$SCRIPT" . Dockerfile )
rec_2=$(  cd "$FIX" && bash "$SCRIPT" packages/worker packages/worker/Dockerfile )
assert_ne "context file change moves the tag" "$root_1" "$root_2"
assert_eq "change outside a context leaves it alone" "$rec_1" "$rec_2"

# A .dockerignore'd file never enters the image, so it must not move the tag.
commit_change "$FIX" node_modules/x.js "junk v2"
root_3=$( cd "$FIX" && bash "$SCRIPT" . Dockerfile )
assert_eq "dockerignored file does not move the tag" "$root_2" "$root_3"

# The Dockerfile is the recipe: it counts even when .dockerignore excludes it.
commit_change "$FIX" .dockerignore "node_modules
Dockerfile"
root_4=$( cd "$FIX" && bash "$SCRIPT" . Dockerfile )
commit_change "$FIX" Dockerfile "FROM alpine"
root_5=$( cd "$FIX" && bash "$SCRIPT" . Dockerfile )
assert_ne "dockerignored Dockerfile still moves the tag" "$root_4" "$root_5"

# Failure modes: an empty list must not hash to a valid-looking tag.
assert_fails "missing arguments fail"    bash "$SCRIPT"
assert_fails "one argument fails"        bash "$SCRIPT" .
( cd "$FIX" && bash "$SCRIPT" no/such/dir Dockerfile ) >/dev/null 2>&1
assert_eq "nonexistent context exits non-zero" "1" "$?"

rm -rf "$FIX"
finish
