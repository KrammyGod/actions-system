#!/usr/bin/env bash
# Glue for the publish composite action: render the pinned manifests, verify
# every pin landed, and push the result to a registry as a Flux OCI artifact.
#
#   PINS       TSV of <name>\t<newName>\t<newTag>
#   NAMESPACE  namespace the manifests are rendered into
#   ARTIFACT   oci://<registry>/<ns>-manifests, without a tag
#   SHA        commit sha; becomes the immutable artifact tag
#   TAG        moving tag the cluster follows
#   SOURCE     repo URL, recorded as artifact provenance
#   REVISION   <ref>@sha1:<sha>, recorded as artifact provenance
#   PUSH       "true" to push; anything else renders and verifies only
#   KDIR       kustomize root, relative to the repo
#   OVERLAY    overlay path relative to KDIR
set -euo pipefail

# Resolve the sibling script from our own location rather than an env var, so
# the script runs standalone under test with no Actions context at all.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
wrapper=$here/make-wrapper.sh

: "${PINS:?PINS is required}"
: "${NAMESPACE:?NAMESPACE is required}"
: "${ARTIFACT:?ARTIFACT is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
KDIR=${KDIR:-kustomize}
OVERLAY=${OVERLAY:-overlays/prod}
TAG=${TAG:-main}
PUSH=${PUSH:-false}
SOURCE=${SOURCE:-}
REVISION=${REVISION:-}

# The wrapper sits one level below the workspace root so `resources:`
# is a simple ../ hop into the real overlay.
out="$GITHUB_WORKSPACE/.ci-wrapper"
dist="$GITHUB_WORKSPACE/.ci-manifests"

printf '%s' "$PINS" | bash "$wrapper" "$out" "../$KDIR/$OVERLAY" "$NAMESPACE"

echo "--- wrapper ---"
cat "$out/kustomization.yaml"

# Rendered here rather than in-cluster: kustomize-controller would otherwise
# resolve the overlay itself on a memory-constrained node, and the exact bytes
# that get applied would never appear in a log anyone reads.
rm -rf "$dist"
mkdir -p "$dist"
kubectl kustomize "$out" > "$dist/manifests.yaml"

if [ ! -s "$dist/manifests.yaml" ]; then
    echo "publish: rendered manifests are empty" >&2
    exit 1
fi

echo "--- rendered ---"
grep -E '^(kind|  name):' "$dist/manifests.yaml" || true

missing=0
while IFS="$(printf '\t')" read -r _ newname newtag; do
    [ -n "$newname" ] || continue
    if ! grep -qF "image: $newname:$newtag" "$dist/manifests.yaml"; then
        echo "publish: pin $newname:$newtag matched no image in the render" >&2
        missing=1
    fi
done < <(printf '%s\n' "$PINS")

if [ "$missing" -ne 0 ]; then
    exit 1
fi

if [ "$PUSH" != "true" ]; then
    echo "publish: not a main build — rendered and verified, nothing pushed"
    exit 0
fi

: "${SHA:?SHA is required to push}"

# Immutable tag first, then move the tag the cluster follows onto it. That
# order matters: the moving tag never points at a digest that was not pushed,
# so a failure between the two leaves the cluster on the previous good artifact
# rather than chasing one that does not exist.
flux push artifact "$ARTIFACT:$SHA" \
    --path="$dist" \
    --source="$SOURCE" \
    --revision="$REVISION"

flux tag artifact "$ARTIFACT:$SHA" --tag "$TAG"
