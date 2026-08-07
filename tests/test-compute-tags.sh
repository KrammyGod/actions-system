#!/usr/bin/env bash
# Behaviour of the checksum action's glue.
#
# This logic used to be inline in action.yml, where the only thing a test could
# do was substring-match the YAML — test_workflows.py said as much in a comment:
# "matching prose rather than code is how this check lies to you." Now it runs.
#
# The assertion that matters most is the three-field pin. An empty newName
# collapses under `read`, because tab is IFS whitespace, and the result deploys
# `src-<tag>:latest` — which applies cleanly and ships nothing. It is verified
# here by parsing the emitted TSV and by feeding it to the real wrapper, not by
# grepping for a printf format string.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.github/actions/checksum/compute-tags.sh"
WRAPPER="$ROOT/.github/actions/publish/make-wrapper.sh"
TAB=$(printf '\t')

# Two build contexts: the repo root and a nested one, so default resolution of
# `dockerfile` from `context` is exercised both ways.
make_fixture() {
    d=$(mktemp -d)
    (
        cd "$d" || exit 1
        git init -q
        git config user.email t@example.com
        git config user.name tester
        mkdir -p packages/worker
        printf 'FROM scratch\n' > Dockerfile
        printf 'app v1\n'       > app.js
        printf 'FROM scratch\n' > packages/worker/Dockerfile
        printf 'rec v1\n'       > packages/worker/main.go
        git add -A
        git commit -qm init
    )
    printf '%s' "$d"
}

OUT_FILE=""
run_glue() { # <dir> <images-json> [dev-suffix]
    OUT_FILE=$(mktemp)
    (
        cd "$1" || exit 1
        IMAGES="$2" REGISTRY=ghcr.io/krammygod DEV_SUFFIX="${3:-}" \
            GITHUB_OUTPUT="$OUT_FILE" bash "$SCRIPT"
    ) >/dev/null
}

# The step output file is `key=value` plus a heredoc block for the multi-line
# pins, exactly as the runner parses it.
out_tags() { sed -n 's/^tags=//p' "$OUT_FILE"; }
out_pins() { sed -n '/^pins<<PINS_EOF$/,/^PINS_EOF$/p' "$OUT_FILE" | sed '1d;$d'; }

# Distinct field counts across every pin line, joined. "3" means all lines have
# three fields; "2,3" would mean at least one is short.
#
# Necessary but NOT sufficient, and the difference is the whole bug: awk splits
# on every tab, so `name\t\ttag` counts as three fields and looks fine here.
# `read` treats runs of tabs as one delimiter and sees two. The assertions that
# actually catch it are the `read`-based ones and the wrapper round-trip below.
field_counts() { printf '%s\n' "$1" | awk -F'\t' '{print NF}' | sort -u | paste -sd, -; }

FIX=$(make_fixture)

# --- defaults: a bare {"name": x} means context "." and ./Dockerfile ---------
run_glue "$FIX" '[{"name":"example-app"}]'

assert_match "tags is a JSON map of name -> src-<12 hex>" \
    '^\{"example-app":"src-[0-9a-f]{12}"\}$' "$(out_tags)"

pins=$(out_pins)
assert_eq "one pin line per image" "1" "$(printf '%s\n' "$pins" | wc -l | tr -d ' ')"
assert_eq "the pin carries exactly three fields" "3" "$(field_counts "$pins")"

# Read it back with the same semantics make-wrapper.sh uses: if the middle
# field were empty, the tag would land in p_newname and p_tag would be empty.
IFS="$TAB" read -r p_name p_newname p_tag <<< "$pins"
assert_eq "pin name is registry-qualified" \
    "ghcr.io/krammygod/example-app" "$p_name"
assert_eq "newName repeats name when there is no dev suffix" \
    "ghcr.io/krammygod/example-app" "$p_newname"
assert_match "pin tag is the content hash" '^src-[0-9a-f]{12}$' "$p_tag"

# --- dev suffix and per-context tags ----------------------------------------
run_glue "$FIX" \
    '[{"name":"example-app"},{"name":"worker","context":"packages/worker"}]' '-dev'

pins=$(out_pins)
assert_eq "one pin line per image" "2" "$(printf '%s\n' "$pins" | wc -l | tr -d ' ')"
assert_eq "every pin line carries exactly three fields" "3" "$(field_counts "$pins")"

assert_match "dev suffix lands on newName and leaves name alone" \
    "^ghcr\.io/krammygod/example-app${TAB}ghcr\.io/krammygod/example-app-dev${TAB}src-[0-9a-f]{12}$" \
    "$pins"

tags=$(out_tags)
assert_ne "each context resolves its own Dockerfile and its own tag" \
    "$(printf '%s' "$tags" | jq -r '."example-app"')" \
    "$(printf '%s' "$tags" | jq -r '.worker')"

# --- the two halves must agree ----------------------------------------------
# The \t\t bug was only ever observable by running the emitter and the consumer
# together: the emitted TSV looked fine, and the wrapper applied cleanly.
W=$(mktemp -d)
printf '%s\n' "$pins" | bash "$WRAPPER" "$W/.ci-wrapper" ../overlay
rendered=$(cat "$W/.ci-wrapper/kustomization.yaml")
assert_match "wrapper reads newName back out of the emitted pins" \
    'newName: ghcr\.io/krammygod/example-app-dev' "$rendered"
assert_match "wrapper reads newTag back out of the emitted pins" \
    'newTag: src-[0-9a-f]{12}' "$rendered"
assert_no_match "no image is pinned to a tag-shaped name" \
    'newName: src-' "$rendered"
rm -rf "$W"

# --- guards -----------------------------------------------------------------
assert_fails "missing IMAGES fails" \
    env -u IMAGES REGISTRY=r GITHUB_OUTPUT=/dev/null bash "$SCRIPT"
assert_fails "missing REGISTRY fails" \
    env -u REGISTRY IMAGES='[]' GITHUB_OUTPUT=/dev/null bash "$SCRIPT"
assert_fails "missing GITHUB_OUTPUT fails" \
    env -u GITHUB_OUTPUT IMAGES='[]' REGISTRY=r bash "$SCRIPT"

# A mistyped context used to hash the Dockerfile alone, producing a valid tag
# that never changed, so the registry probe skipped that image forever.
assert_fails "a mistyped context fails instead of hashing the Dockerfile alone" \
    env IMAGES='[{"name":"x","context":"no/such/dir"}]' REGISTRY=r \
        GITHUB_OUTPUT=/dev/null bash -c "cd '$FIX' && bash '$SCRIPT'"

rm -rf "$FIX"
finish
