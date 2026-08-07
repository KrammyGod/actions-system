#!/usr/bin/env bash
# Glue for the release workflow: tag the commit, move the major alias, publish.
#
#   BUMP           auto|patch|minor|major (default auto)
#   GITHUB_OUTPUT  Actions
#   GH_TOKEN       read by gh
set -euo pipefail

# Resolve the sibling script from our own location rather than an env var, so
# the script runs standalone under test with no Actions context at all.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
nextver=$here/next-version.sh

BUMP=${BUMP:-auto}

# Only vX.Y.Z, never the vX aliases — an alias sorts as a release and would
# make the range start at the wrong commit.
latest=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)

if [ -n "$latest" ]; then
    range="$latest..HEAD"
else
    range=HEAD
fi

version=$(git log --format=%B "$range" | bash "$nextver" "$latest" "$BUMP")

if [ -z "$version" ]; then
    echo "release: nothing since ${latest:-the first commit} warrants a release"
    exit 0
fi

# v1.4.2 -> v1. Callers pin the alias, so a release nobody's @v1 points at is
# a release that changed nothing for any consumer.
alias=${version%%.*}

echo "release: ${latest:-none} -> $version (alias $alias)"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git tag -a "$version" -m "$version"
git push origin "$version"

git tag -f -a "$alias" -m "$alias"
git push -f origin "$alias"

# --generate-notes diffs against the previous release, so this is empty on the
# very first one and complete after that.
gh release create "$version" --title "$version" --generate-notes

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$version"
        echo "alias=$alias"
    } >> "$GITHUB_OUTPUT"
fi
