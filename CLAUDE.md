# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Reusable GitHub Actions workflows that build application images and publish
rendered Kubernetes manifests for Flux to apply. Consumers are the application
repositories that call `deploy.yml`; the cluster and its Flux configuration live
in a separate infrastructure repository. See `README.md` for the caller-facing
contract; this file covers what you need to change the pipeline itself.

## Commands

```sh
bash tests/run-all.sh                  # lint + everything
bash tests/lint.sh                     # shellcheck alone
bash tests/test-compute-tags.sh        # one shell suite
bash tests/test-context-checksum.sh
bash tests/test-make-wrapper.sh
bash tests/test-next-version.sh
bash tests/test-publish.sh
bash tests/test-release.sh
python tests/test_workflows.py         # YAML structure
```

Needs `kubectl` (for its bundled Kustomize), `git`, `jq`, and PyYAML. There is
no build step. `tests/run-all.sh` picks up any `tests/test-*.sh` automatically
and runs `lint.sh` first.

`shellcheck` is the linter. It is optional locally — `lint.sh` skips itself with
a notice when it is absent — and mandatory in CI, which installs it. `pip
install shellcheck-py` is the quickest way to get it on Windows.

## What can and cannot be tested here

Workflows cannot run outside Actions, so **all real logic lives in `.sh` files
inside the two composite actions**, and both the workflow YAML and the actions'
`run:` blocks are thin glue. That split is deliberate — keep it.

Each `run:` is a single `bash "$SCRIPT"`. Logic added to a `run:` block is
invisible to shellcheck and unreachable by every test here, so the only way to
find out it is wrong is to ship it. `test_workflows.py` enforces the one-line
shape, and that check is the reason the rule holds.

The suites split by what they can prove:

- `test-context-checksum.sh`, `test-make-wrapper.sh` — the two pure scripts,
  called directly with arguments.
- `test-compute-tags.sh` — the checksum glue, run with `GITHUB_OUTPUT` pointed
  at a temp file, then its emitted pins fed to the real `make-wrapper.sh`. The
  `\t\t` bug is only visible when both halves run together.
- `test-publish.sh` — the publish glue, against `kubectl` and `flux` stubs on
  `PATH`. `kustomize` delegates to the real binary so a broken wrapper still
  fails, and the flux stub logs what would have been pushed.
- `test-next-version.sh` — the bump rules, called directly with arguments.
- `test-release.sh` — the release glue against a **real** bare remote on disk,
  so `git push` and the force-move of the major alias are exercised rather than
  stubbed. Only `gh` is faked. This is what proves `v1` follows `v1.1.0` and
  stays frozen when `v2` is cut.
- `test_workflows.py` — the caller contract only: input names, defaults, the job
  graph, and the condition gating the push. When you add an input, add it there
  too or the suite fails on the exact-set comparison.

**Do not assert behaviour by substring-matching a script's source.**
`test_workflows.py` used to grep the inline `run:` bodies for things like
`refusing to report success`. Those checks passed whether or not the guard
worked; the guard is now removed and re-added by mutation to confirm the
replacement tests actually fail.

## Architecture

```
checksum job  ──> .github/actions/checksum/
                    context-checksum.sh  -> src-<12 hex> for one context
                    compute-tags.sh      -> tags (JSON map) + pins (TSV)
                    action.yml           -> bash "$SCRIPT", nothing else
build job     ──> matrix over images, probe registry, skip or build
publish job   ──> .github/actions/publish/
                    make-wrapper.sh      -> wrapper kustomization
                    publish.sh           -> render, verify pins, push artifact
                    action.yml           -> bash "$SCRIPT", nothing else
```

Everything runs on `ubuntu-24.04-arm`. **No job touches the cluster**, and
`test_workflows.py` asserts that: no `self-hosted`, no `KUBECONFIG`, every
`runs-on` equal to `${{ inputs.runner }}`. Deploys are pull-based — CI pushes
rendered manifests to GHCR and Flux applies them. Anything that reintroduces a
cluster credential here is a regression, not a feature.

The pipeline is still a reusable workflow rather than one composite action,
because a composite action cannot declare the build matrix.

Each action is two scripts: a **pure** one (arguments in, stdout out, no Actions
context) and the **glue** that reads the `inputs.*` env. The glue used to be
inline in `action.yml`. It is a file now so shellcheck can see it and the tests
can execute it; a script finds its pure sibling via its own `$0`, not an env
var, so it runs standalone under test.

**Tags are computed once** in `checksum` and consumed by both later jobs, so
build and publish cannot disagree about what shipped. Never recompute a tag
downstream.

**Images are pinned with a generated wrapper kustomization, never `sed`.**
`make-wrapper.sh` writes a `kustomization.yaml` that has `resources: [../<overlay>]`
plus an `images:` block; `publish.sh` renders it. Kustomize matches image names
*exactly*, so a pin is a bare name with no tag — which is the advantage over the
`sed` it replaces, since a safe textual substitution must include the tag and is
therefore coupled to one exact placeholder string. It matches whatever tag is
committed, so app repos need no manifest changes. An outer wrapper also
overrides an `images:` block committed inside the overlay it wraps.

### The pins TSV contract

`compute-tags.sh` emits, and both `make-wrapper.sh` and `publish.sh` consume,
one line per image:

```
<name>\t<newName>\t<newTag>
```

**All three fields are always present.** `newName` repeats `name` when there is
no `-dev` suffix. Leaving it empty is the obvious encoding and is wrong: tab is
an IFS whitespace character, so `read` collapses `\t\t` into one delimiter, the
tag lands in `newName`, and the result renders as `image: src-<tag>:latest` —
which applies cleanly and deploys nothing real. `make-wrapper.sh` rejects a
two-field line for this reason.

Counting fields with `awk` does not catch this and `test-compute-tags.sh` says
so in a comment: `awk -F'\t'` splits on every tab and sees three fields in
`name\t\ttag`, while `read` collapses the run and sees two. Verify with `read`,
or by rendering the wrapper.

### The artifact name is derived, not configured

`oci://<registry>/<namespace>-manifests`, built in `deploy.yml` and built again
by hand in the cluster-side `OCIRepository`. There is no input for it on
purpose: two knobs that must agree is one knob too many. Changing the shape
means editing both repos, and `test_workflows.py` pins the CI half of it.

## Traps

- **Kustomize's image transformer is a silent no-op on an unmatched `name`.**
  Nothing downstream notices — Flux applies manifests still carrying `:latest`
  and reports Ready, and under the old push model `kubectl rollout status`
  passed too because the running pod was already healthy. `publish.sh` greps the
  render for every pin and fails if one is absent. Keep that check.
- **A mistyped `context` used to hash to a valid tag.** `git ls-tree` returns
  nothing, but the Dockerfile is appended unconditionally, so the empty-list
  guard never fired. The tag then covered the Dockerfile alone, never changed,
  and the registry probe skipped that image forever. `context-checksum.sh`
  now validates the context and the Dockerfile separately, *before* they are
  combined. Keep those checks apart.
- **The immutable `:<sha>` tag is pushed before `:main` moves onto it.** Reverse
  the order and a failure between the two points the cluster at a digest that
  does not exist.
- **An empty render would prune everything.** The cluster's `Kustomization` has
  `prune: true`, so an artifact containing nothing deletes every object Flux
  owns in that namespace. `publish.sh` refuses to push an empty render.
- **Namespaces are cluster-side now.** The infrastructure repo's Flux config
  creates them; CI cannot. A namespace that does not exist fails the Flux
  reconcile rather than being created silently, which is the intended
  behaviour — the old `apply.sh` created a mistyped namespace instead.
- **A GHCR package created outside Actions is unreachable from Actions.** A push
  from a laptop or with a PAT does not link the package to any repository, even
  when the names match, and `GITHUB_TOKEN` then 403s on it forever until someone
  links it by hand in the UI. A package created *by* a workflow is linked
  automatically. The practical rule: **never pre-create a package** — let the
  first run make it. Migrating a repo that used a PAT means linking each
  existing image and its `-dev` twin once; see README.md § Migrating.
- **A caller must grant `packages: write` itself.** A reusable workflow can only
  downgrade the caller's `GITHUB_TOKEN`, so `deploy.yml` cannot grant it — it
  only *declares* it, which turns a caller's omission into a validation error
  naming the permission instead of a 403 mid-push. There is deliberately no
  `secrets:` block: a reusable workflow sees only the caller's secrets, so a PAT
  would mean one stored per consuming repo, each expiring separately.
- **Scripts are invoked as `bash <script>`, never `./script`.** Git on Windows
  does not record the exec bit, so a `./` invocation would break in CI.
- **`pipefail` is deliberately absent from `context-checksum.sh`.** `git
  check-ignore` exits 1 when none of the given paths are ignored — the normal
  case for a context with no `.dockerignore` — and `grep '^::'` exits 1 on no
  matches. Under `pipefail` both turn a working build into a failed one. The
  glue scripts use `set -euo pipefail`; these two use `set -eu`.
- **`grep` needs `--` before a pattern that starts with a dash.** `assert_match`
  learned this asserting on `--revision=...`: grep parsed the pattern as an
  option, printed a usage error to stderr, and the assertion reported a
  mismatch that read exactly like a product bug.
- **A comment starting `# shellcheck ...` is parsed as a directive.** It cost
  `tests/lint.sh` its own first line, which now reads "Runs shellcheck over...".
- **`jq` on Windows emits CRLF.** The checksum action pipes through `tr -d '\r'`;
  without it a trailing `\r` corrupts the last TSV field. Harmless on the Linux
  runner, but the action stays runnable from a Windows checkout.

## Conventions

- Scripts are `bash`, with `#!/usr/bin/env bash`. The glue scripts use
  `set -euo pipefail`; `context-checksum.sh` and `make-wrapper.sh` use `set -eu`
  for the reason in Traps. Everything must pass `shellcheck -x`.
- Never write `[ cond ] && cmd` as a standalone statement under `set -e` — a
  false condition returns 1 and exits the script. Use `if`/`fi`.
- Comments explain *why*. Every guard in these scripts exists because something
  failed silently; say what, so nobody "simplifies" it away. Design rationale
  and history belong in `README.md`, not in the code.
- Callers pin `@v1`, and `release.yml` moves it automatically on every push to
  main whose commits warrant a release. **Write conventional commits or the
  change ships to nobody** — `docs:` and `chore:` tag nothing. A `!` or a
  `BREAKING CHANGE:` footer cuts `v2` and freezes `v1`, which is the safe
  outcome but means no existing caller receives the change until it edits its
  `uses:` line. Do not mark a change breaking casually, and never tag by hand.

## Untested

Nothing here has run end to end. Neither the `flux push artifact` step nor the
cluster-side reconcile has been exercised; the flux CLI is stubbed in tests, and
the version installed in CI (2.9.1) was chosen to match the controllers the
cluster installs, not verified against them.
