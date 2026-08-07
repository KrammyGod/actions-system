#!/usr/bin/env bash
# Behaviour of the publish action's glue.
#
# A kubectl stub delegates `kustomize` to the real binary so the rendering is
# genuine, and a flux stub records what would have been pushed. Nothing here
# needs a cluster or a registry, which is the point of the pull model.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.github/actions/publish/publish.sh"
TAB=$(printf '\t')
REAL_KUBECTL=$(command -v kubectl)
PIN="ghcr.io/krammygod/example-app${TAB}ghcr.io/krammygod/example-app-dev${TAB}src-aaaaaaaaaaaa"

if [ -z "$REAL_KUBECTL" ]; then
    printf 'kubectl not installed — cannot render the overlay\n' >&2
    exit 1
fi

# A miniature app repo, plus stub kubectl and flux binaries on PATH.
make_workspace() { # [overlay-resources]
    d=$(mktemp -d)
    mkdir -p "$d/kustomize/overlays/prod" "$d/bin"
    cat > "$d/kustomize/overlays/prod/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
spec:
  template:
    spec:
      containers:
        - name: server
          image: ghcr.io/krammygod/example-app:latest
YAML
    cat > "$d/kustomize/overlays/prod/kustomization.yaml" <<YAML
resources: ${1:-[deployment.yaml]}
YAML
    cat > "$d/bin/kubectl" <<STUB
#!/usr/bin/env bash
case "\$1" in
    kustomize) exec "$REAL_KUBECTL" "\$@" ;;
esac
exit 0
STUB
    cat > "$d/bin/flux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FLUX_LOG"
exit 0
STUB
    chmod +x "$d/bin/kubectl" "$d/bin/flux"
    printf '%s' "$d"
}

LOG=""
run_publish() { # <workspace> <push> [pins]
    LOG="$1/flux.log"
    : > "$LOG"
    PATH="$1/bin:$PATH" \
    FLUX_LOG="$LOG" \
    GITHUB_WORKSPACE="$1" \
    PINS="${3:-$PIN}" \
    NAMESPACE=example-app \
    ARTIFACT=oci://ghcr.io/krammygod/example-app-manifests \
    SHA=cafebabe SOURCE=https://github.com/KrammyGod/example-app \
    REVISION=main@sha1:cafebabe TAG=main \
    PUSH="$2" \
    KDIR=kustomize OVERLAY=overlays/prod \
        bash "$SCRIPT"
}

# --- a main build: render, then push both tags ------------------------------
WS=$(make_workspace)
run_publish "$WS" true >/dev/null 2>&1
rc=$?
log=$(cat "$LOG")

assert_eq "a main build succeeds" "0" "$rc"
assert_match "the immutable tag is the commit sha" \
    'push artifact oci://ghcr\.io/krammygod/example-app-manifests:cafebabe' "$log"
assert_match "provenance is recorded on the artifact" \
    '--revision=main@sha1:cafebabe' "$log"
assert_match "the moving tag the cluster follows is set" \
    'tag artifact oci://ghcr\.io/krammygod/example-app-manifests:cafebabe --tag main' "$log"

# The moving tag must never point at a digest that was not pushed, so a failure
# between the two leaves the cluster on the previous good artifact.
assert_eq "the immutable push happens before the tag move" "push artifact" \
    "$(printf '%s\n' "$log" | head -1 | cut -d' ' -f1-2)"

# What gets pushed is the rendered output, not the overlay: kustomize runs here
# so kustomize-controller does not have to, and so the bytes appear in a log.
rendered=$(cat "$WS/.ci-manifests/manifests.yaml")
assert_match "the render carries the pinned image" \
    'image: ghcr\.io/krammygod/example-app-dev:src-aaaaaaaaaaaa' "$rendered"
assert_no_match "and no longer carries the committed tag" \
    'example-app:latest' "$rendered"

wrapper=$(cat "$WS/.ci-wrapper/kustomization.yaml")
assert_match "the wrapper pins newName" 'newName: ghcr\.io/krammygod/example-app-dev' "$wrapper"
assert_match "the wrapper pins newTag" 'newTag: src-aaaaaaaaaaaa' "$wrapper"
assert_match "the wrapper retargets the namespace" 'namespace: example-app' "$wrapper"
rm -rf "$WS"

# --- a pull request: render and verify, push nothing ------------------------
WS=$(make_workspace)
run_publish "$WS" false >/dev/null 2>&1
rc=$?

assert_eq "a PR build succeeds" "0" "$rc"
assert_eq "a PR pushes no artifact" "" "$(cat "$LOG")"
assert_eq "but it still renders, so a broken overlay fails the PR" "0" \
    "$([ -s "$WS/.ci-manifests/manifests.yaml" ] && echo 0 || echo 1)"
rm -rf "$WS"

# --- a pin that matches nothing ---------------------------------------------
# Kustomize's image transformer is a silent no-op on a name it cannot find, so
# without this guard the artifact would ship :latest and Flux would report Ready.
WS=$(make_workspace)
run_publish "$WS" true \
    "ghcr.io/krammygod/typo${TAB}ghcr.io/krammygod/typo-dev${TAB}src-bbbbbbbbbbbb" \
    >/dev/null 2>&1
rc=$?

assert_ne "a pin matching no image in the overlay fails" "0" "$rc"
assert_eq "and nothing is pushed" "" "$(cat "$LOG")"
rm -rf "$WS"

# --- an empty render --------------------------------------------------------
# An overlay with no resources renders to nothing, which would push an empty
# artifact and prune every object Flux owns in that namespace.
WS=$(make_workspace "[]")
run_publish "$WS" true >/dev/null 2>&1
rc=$?

assert_ne "an empty render fails" "0" "$rc"
assert_eq "and nothing is pushed" "" "$(cat "$LOG")"
rm -rf "$WS"

# --- guards -----------------------------------------------------------------
WS=$(make_workspace)
assert_fails "missing PINS fails" \
    env -u PINS NAMESPACE=ns ARTIFACT=oci://x GITHUB_WORKSPACE="$WS" bash "$SCRIPT"
assert_fails "missing NAMESPACE fails" \
    env -u NAMESPACE PINS=x ARTIFACT=oci://x GITHUB_WORKSPACE="$WS" bash "$SCRIPT"
assert_fails "missing ARTIFACT fails" \
    env -u ARTIFACT PINS=x NAMESPACE=ns GITHUB_WORKSPACE="$WS" bash "$SCRIPT"
assert_fails "missing GITHUB_WORKSPACE fails" \
    env -u GITHUB_WORKSPACE PINS=x NAMESPACE=ns ARTIFACT=oci://x bash "$SCRIPT"
rm -rf "$WS"

finish
