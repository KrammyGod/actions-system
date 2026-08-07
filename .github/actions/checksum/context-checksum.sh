#!/usr/bin/env bash
# Content checksum of a docker build context, used as the image tag.
#
#   context-checksum.sh <context> <dockerfile> [rev]
#
# Paths come from .dockerignore, not a hardcoded list, so the two cannot drift.
# git check-ignore evaluates the patterns; its gitignore semantics match
# dockerignore for plain names and directories, but differ for `**` and for
# root-anchoring, so exotic patterns need checking by hand.
set -eu

export LC_ALL=C

context=${1:-}
dockerfile=${2:-}
rev=${3:-HEAD}

if [ -z "$context" ] || [ -z "$dockerfile" ]; then
    echo "usage: $0 <context> <dockerfile> [rev]" >&2
    exit 1
fi

ignore="$context/.dockerignore"
[ -f "$ignore" ] || ignore=/dev/null

# Every tracked file under the context, before .dockerignore is applied.
#
# Checked on its own rather than after the Dockerfile is appended below: a
# mistyped context yields nothing here, but the appended Dockerfile would keep
# the final list non-empty and hash to a perfectly valid-looking tag. That tag
# would cover the Dockerfile alone and never change again, so every build after
# the typo would be silently skipped by the registry probe.
tracked=$(git ls-tree -r --name-only "$rev" -- "$context")
if [ -z "$tracked" ]; then
    echo "context-checksum: '$context' matched no tracked files at $rev" >&2
    exit 1
fi

# The Dockerfile is the recipe, so it counts even when .dockerignore drops it.
# It must exist, or rev-parse below would fail deep inside a subshell where
# set -e cannot see it.
if ! git rev-parse --quiet --verify "$rev:$dockerfile" >/dev/null 2>&1; then
    echo "context-checksum: dockerfile '$dockerfile' not tracked at $rev" >&2
    exit 1
fi

# Paths in the context: tracked files minus what .dockerignore drops, plus the
# Dockerfile. check-ignore --non-matching --verbose prints "::<TAB>path" for
# files it keeps.
paths=$(
    {
        printf '%s\n' "$tracked" \
            | git -c core.excludesFile="$ignore" check-ignore \
                  --no-index --stdin --non-matching --verbose \
            | grep '^::' | cut -f2
        echo "$dockerfile"
    } | sort -u
)

if [ -z "$paths" ]; then
    echo "context-checksum: no files resolved for $context at $rev" >&2
    exit 1
fi

# Hash the blob id of every file, so the tag tracks content rather than names.
listing=$(printf '%s\n' "$paths" | while IFS= read -r f; do
    printf '%s %s\n' "$(git rev-parse "$rev:$f")" "$f"
done)

printf 'src-%s\n' "$(printf '%s\n' "$listing" | sha1sum | cut -c1-12)"
