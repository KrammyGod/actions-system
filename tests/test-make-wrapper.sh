#!/usr/bin/env bash
# The wrapper is only correct if kustomize agrees, so every assertion here
# renders it with kubectl rather than grepping the generated YAML.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.github/actions/publish/make-wrapper.sh"
TAB=$(printf '\t')

# A miniature app repo: base namespace + a deployment with two images, one of
# which is a name-prefix of the other. That prefix pair is the case a textual
# substitution gets wrong.
make_repo() {
    d=$(mktemp -d)
    mkdir -p "$d/kustomize/overlays/prod"
    cat > "$d/kustomize/overlays/prod/namespace.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: example-app
YAML
    cat > "$d/kustomize/overlays/prod/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
  namespace: example-app
spec:
  template:
    spec:
      containers:
        - name: server
          image: ghcr.io/krammygod/example-app:latest
        - name: worker
          image: ghcr.io/krammygod/example-app-worker:latest
YAML
    cat > "$d/kustomize/overlays/prod/kustomization.yaml" <<'YAML'
resources:
  - namespace.yaml
  - deployment.yaml
YAML
    printf '%s' "$d"
}

ns_name() { # read the Namespace object's own name out of rendered output
    printf '%s' "$1" | grep -A2 'kind: Namespace' | grep '  name:' | head -1 | awk '{print $2}'
}

# --- prod: pin tags, keep names, no namespace override ---------------------
# newName repeats name: an empty middle field would be collapsed by `read`,
# because tab counts as IFS whitespace.
R=$(make_repo)
printf '%s%s%s%ssrc-aaaaaaaaaaaa\n%s%s%s%ssrc-bbbbbbbbbbbb\n' \
    "ghcr.io/krammygod/example-app"          "$TAB" "ghcr.io/krammygod/example-app"          "$TAB" \
    "ghcr.io/krammygod/example-app-worker" "$TAB" "ghcr.io/krammygod/example-app-worker" "$TAB" \
| bash "$SCRIPT" "$R/.ci-wrapper" ../kustomize/overlays/prod
out=$(kubectl kustomize "$R/.ci-wrapper")

assert_match "prod pins the server image" \
    'image: ghcr\.io/krammygod/example-app:src-aaaaaaaaaaaa' "$out"
assert_match "prod pins the worker image separately" \
    'image: ghcr\.io/krammygod/example-app-worker:src-bbbbbbbbbbbb' "$out"
assert_eq "prod leaves the namespace alone" "example-app" "$(ns_name "$out")"
rm -rf "$R"

# --- pr: swap name to -dev and retarget the namespace ----------------------
R=$(make_repo)
printf 'ghcr.io/krammygod/example-app%sghcr.io/krammygod/example-app-dev%ssrc-cccccccccccc\n' "$TAB" "$TAB" \
| bash "$SCRIPT" "$R/.ci-wrapper" ../kustomize/overlays/prod example-app-pr-42
out=$(kubectl kustomize "$R/.ci-wrapper")

assert_match "pr swaps name and tag together" \
    'image: ghcr\.io/krammygod/example-app-dev:src-cccccccccccc' "$out"
assert_match "pr leaves the prefix-sharing image untouched" \
    'image: ghcr\.io/krammygod/example-app-worker:latest' "$out"
assert_eq "pr renames the Namespace object itself" "example-app-pr-42" "$(ns_name "$out")"
assert_match "pr retargets resource namespaces" 'namespace: example-app-pr-42' "$out"
rm -rf "$R"

# --- guards ----------------------------------------------------------------
assert_fails "missing out_dir fails"   bash "$SCRIPT"
assert_fails "missing overlay fails"   bash "$SCRIPT" /tmp/whatever
R=$(make_repo)
assert_fails "empty pins on stdin fails" \
    bash -c "printf '' | bash '$SCRIPT' '$R/.ci-wrapper' ../kustomize/overlays/prod"
rm -rf "$R"

# A two-field line is what an empty newName collapses to. Rendering it would
# rename the image to its own tag and apply cleanly, so it must be refused.
R=$(make_repo)
assert_fails "malformed two-field pin fails" \
    bash -c "printf 'ghcr.io/krammygod/example-app\tsrc-aaaaaaaaaaaa\n' | bash '$SCRIPT' '$R/.ci-wrapper' ../kustomize/overlays/prod"
rm -rf "$R"

finish
