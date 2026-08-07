#!/usr/bin/env bash
# Glue for the checksum composite action: one content-addressed tag per image.
#
#   IMAGES      JSON array of {name, context?, dockerfile?}
#   REGISTRY    registry and owner prefix, e.g. ghcr.io/krammygod
#   DEV_SUFFIX  appended to each image name; empty for prod, "-dev" for PRs
#
# Writes `tags` (JSON map) and `pins` (TSV) to $GITHUB_OUTPUT.
set -euo pipefail

# Resolve the sibling script from our own location rather than an env var, so
# the script runs standalone under test with no Actions context at all.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
checksum=$here/context-checksum.sh

: "${IMAGES:?IMAGES is required}"
: "${REGISTRY:?REGISTRY is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
DEV_SUFFIX=${DEV_SUFFIX:-}

# Defaults applied here, once, so the build matrix and the deploy job
# can never disagree about what a bare {"name": "x"} means.
normalized=$(printf '%s' "$IMAGES" | jq -c '
  map({
    name:       .name,
    context:    (.context    // "."),
    dockerfile: (.dockerfile // ((.context // ".") + "/Dockerfile" | sub("^\\./"; "")))
  })')

tags='{}'
pins=''
while IFS=$'\t' read -r name context dockerfile; do
  [ -n "$name" ] || continue
  tag=$(bash "$checksum" "$context" "$dockerfile")
  # The script guards this, but an empty tag reaching buildx fails
  # minutes later as `invalid reference format`. Fail here instead.
  [ -n "$tag" ] || { echo "no tag produced for $name" >&2; exit 1; }

  tags=$(printf '%s' "$tags" | jq -c --arg k "$name" --arg v "$tag" '.[$k]=$v')

  # Built with printf so the separators are real tabs and cannot be
  # mangled by an editor that expands them.
  #
  # newName is ALWAYS emitted, equal to name when there is no suffix.
  # Leaving it empty would be the natural encoding for "keep the name",
  # but tab is an IFS whitespace character, so `read` collapses the
  # resulting `\t\t` into one delimiter and the tag lands in newName.
  # A redundant newName costs nothing; an empty field silently corrupts.
  src="$REGISTRY/$name"
  pins="${pins}$(printf '%s\t%s\t%s' "$src" "${src}${DEV_SUFFIX}" "$tag")"$'\n'
  echo "$name ($context, $dockerfile) -> $tag"
# tr strips CR: jq on Windows emits CRLF, and a trailing \r on the last
# field turns `HEAD:Dockerfile` into `HEAD:Dockerfile\r`. The runner is
# Linux so this cannot bite in CI, but it makes the action runnable from
# a Windows checkout too.
done < <(printf '%s' "$normalized" | jq -r '.[] | [.name, .context, .dockerfile] | @tsv' | tr -d '\r')

echo "tags=$tags" >> "$GITHUB_OUTPUT"
{
  echo 'pins<<PINS_EOF'
  printf '%s' "$pins"
  echo 'PINS_EOF'
} >> "$GITHUB_OUTPUT"
