#!/usr/bin/env bash
# Next semver from conventional-commit messages on stdin.
#
#   next-version.sh <latest> [bump] < messages
#
# latest is vX.Y.Z, or empty when nothing has been released. bump is
# auto|patch|minor|major; auto reads the messages. Prints the next version, or
# nothing at all when no commit warrants a release.
set -eu

export LC_ALL=C

latest=${1:-}
forced=${2:-auto}

case "$forced" in
    auto | patch | minor | major) ;;
    *)
        echo "next-version: bump must be auto|patch|minor|major, got '$forced'" >&2
        exit 1
        ;;
esac

# No prior release starts at v1.0.0. Callers pin a major alias, so a 0.x phase
# would mean every consumer pinning @v0 and re-pinning later for nothing.
if [ -z "$latest" ]; then
    echo v1.0.0
    exit 0
fi

case "$latest" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "next-version: '$latest' is not vX.Y.Z" >&2
        exit 1
        ;;
esac

rest=${latest#v}
major=${rest%%.*}
rest=${rest#*.}
minor=${rest%%.*}
patch=${rest#*.}

if [ "$forced" != auto ]; then
    bump=$forced
else
    messages=$(cat)
    # Highest wins, so these are checked most-significant first. `type!:` and
    # the BREAKING CHANGE footer are the two conventional-commit spellings of
    # the same thing.
    if printf '%s\n' "$messages" \
        | grep -qE '^[a-z]+(\([^)]*\))?!:|^BREAKING[ -]CHANGE:'; then
        bump='major'
    elif printf '%s\n' "$messages" | grep -qE '^feat(\([^)]*\))?:'; then
        bump='minor'
    # `ci` counts because the shipped workflows ARE the product here — a change
    # to deploy.yml is a release even though it would be noise in an app repo.
    elif printf '%s\n' "$messages" \
        | grep -qE '^(fix|perf|refactor|revert|build|ci)(\([^)]*\))?:'; then
        bump='patch'
    else
        bump='none'
    fi
fi

case "$bump" in
    major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
    minor)
        minor=$((minor + 1))
        patch=0
        ;;
    patch) patch=$((patch + 1)) ;;
    none) exit 0 ;;
esac

printf 'v%s.%s.%s\n' "$major" "$minor" "$patch"
