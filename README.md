# actions-system
Reusable GitHub Actions workflows that build images and deploy to a Kubernetes
cluster via Flux.

One place that owns build-tag-publish, so consuming repositories stop carrying
their own drifting copies of it.

Nothing here talks to the cluster. CI builds images, renders the manifests with
those images pinned, and pushes the result to GHCR as an OCI artifact; Flux,
running in the cluster, pulls and applies it. The cluster half — the
`OCIRepository` and `Kustomization` objects — lives in a separate
infrastructure repository.

## Using it

```yaml
name: Deploy
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }

jobs:
  test:
    runs-on: ubuntu-24.04-arm
    steps: [ ... whatever this repo needs ... ]

  deploy:
    needs: [test]
    permissions:
      contents: read
      packages: write
    uses: KrammyGod/actions-system/.github/workflows/deploy.yml@v1
    with:
      namespace: my-app
      images: '[{"name":"my-app"}]'
```

No secrets. Pushes authenticate with the built-in `GITHUB_TOKEN`, which is why
`permissions:` is mandatory — see below.

Lint and test stay in the caller. Go versus Node is the one thing these repos
genuinely differ on, and it is not abstracted here.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `namespace` | *required* | Also names the manifest artifact: `<registry>/<namespace>-manifests`. |
| `images` | *required* | JSON array. `context` defaults `.`, `dockerfile` defaults `<context>/Dockerfile`. |
| `registry` | `ghcr.io/krammygod` | |
| `kustomize_dir` | `kustomize` | |
| `overlay` | `overlays/prod` | Relative to `kustomize_dir`. |
| `runner` | `ubuntu-24.04-arm` | |

No secrets. Outputs `tags`, a JSON map of image name to the tag that was built.

### Multiple images

```yaml
      images: |
        [{"name": "example-app",    "context": "."},
         {"name": "example-worker", "context": "packages/worker"}]

      images: |
        [{"name": "example-api-login",    "dockerfile": "Dockerfile.login"},
         {"name": "example-api-register", "dockerfile": "Dockerfile.register"}]
```

## How tags work

Every image is tagged `src-<12 hex>`, a hash of the git blob IDs of everything
that actually enters its build context. The file list comes from
`.dockerignore`, so the two cannot drift.

Two consequences:

- **Unchanged images are not rebuilt.** The build job probes the registry for
  the tag first and skips on a hit.
- **The tag identifies content, not a commit.** Two commits with identical
  build contexts produce the same image, deliberately.

A mistyped `context` is rejected rather than hashed. Without that check the
context would resolve to no files, the Dockerfile would be appended anyway, and
the result would be a stable valid-looking tag covering the Dockerfile alone —
which the registry probe would then skip forever.

## How images get pinned

App repos commit no `images:` block and no tag discipline — manifests just say
`ghcr.io/krammygod/example-app`. The publish job generates a wrapper
kustomization that references the real overlay and pins each image:

```yaml
resources: [../kustomize/overlays/prod]
namespace: example-app
images:
  - name: ghcr.io/krammygod/example-app
    newName: ghcr.io/krammygod/example-app-dev    # -dev on pull requests
    newTag: src-a1b2c3d4e5f6
```

Kustomize matches `name` **exactly**, so a pin is written as a bare image name
with no tag. That is what makes it better than the `sed` it replaces: a textual
substitution has to include the tag (`example-app:latest` →
`example-app:src-...`) to be safe against prefixes, which couples every deploy
to one exact placeholder string. The old per-repo workflows did that, and
`grep -rl ... | xargs -r sed` is a silent no-op when nothing matches — a
manifest using any other placeholder
was never pinned, and `kubectl rollout status` passed anyway because the
already-running pods were healthy.

Kustomize's image transformer is a **silent no-op** on a `name` it cannot find,
so the publish job greps the rendered output for each pin and fails if one did
not land. Without that, a renamed image would ship an artifact still carrying
`:latest` and Flux would report it healthy.

## How it reaches the cluster

`kubectl kustomize` runs in CI, and the rendered YAML — not the overlay — is
what gets pushed:

```
flux push artifact oci://ghcr.io/krammygod/<ns>-manifests:<sha>
flux tag  artifact oci://ghcr.io/krammygod/<ns>-manifests:<sha> --tag main
```

The cluster's `OCIRepository` follows `:main` and redeploys within a minute of
the digest changing. The immutable `:<sha>` tag is what you pin to roll back.
The two are pushed in that order on purpose: `:main` never points at a digest
that was not pushed, so a failure between them leaves the cluster on the last
good artifact.

Rendering in CI rather than in-cluster keeps kustomize off a memory-constrained
node and puts the exact bytes that will be applied into the workflow log.

Pull requests build and push `-dev` images and render their manifests, but
publish nothing. A broken build or a broken overlay still fails the PR.

## Migrating a repo onto this

### 1. Grant `packages: write` on the calling job

**This is the step that is easy to miss, and it is not optional.**

```yaml
  deploy:
    needs: [test]
    permissions:
      contents: read     # required once `permissions:` is present at all
      packages: write
    uses: KrammyGod/actions-system/.github/workflows/deploy.yml@v1
```

A called workflow can only *downgrade* the caller's `GITHUB_TOKEN`, never
elevate it, so this cannot be granted from inside `deploy.yml` on the caller's
behalf. Every repo here defaults to read-only (`default_workflow_permissions:
read`), so without the block the token has no write access to GHCR.

Two things follow from that:

- **`permissions:` is all-or-nothing.** The moment the key appears, anything
  unlisted is dropped — which is why `contents: read` is spelled out. Omitting
  it breaks `actions/checkout`.
- **Forgetting the block fails loudly.** `deploy.yml`'s jobs declare
  `packages: write` themselves, so a caller granting less fails at workflow
  validation with a message naming the permission, rather than 403-ing halfway
  through a `docker push`.

### 2. Delete the old workflow and its PAT

`publish.yml`/`pull_request.yml` and their `sed`-based image pinning go away
entirely. Any `GHCR_PAT` repo secret can go with them — nothing here reads one.

Strip whatever the old pipeline maintained along with it: a `:latest`
placeholder, or an `images:` block with a `newTag:`. Both are overridden by the
wrapper and become frozen the moment the `sed` that updated them is deleted.
The rendered output is unchanged either way — verify with `kubectl kustomize`
before and after if the namespace is already live.

### 3. Link any package that already exists

**This is the step that bites, and it only applies to packages that already
exist.** GitHub's rule:

> The easiest way to connect a repository to a container package is to publish
> the package from a workflow using `GITHUB_TOKEN`, as the repository that
> contains the workflow is linked automatically. […] the `GITHUB_TOKEN` will not
> have permission to push the package if you have previously pushed a package to
> the same namespace, but have not connected the package to the repository.

So there are two cases, and they need opposite actions:

| Package | What to do |
|---|---|
| **Does not exist yet** | **Nothing.** The first workflow push creates it *and* links it to the calling repo with write access. |
| **Already exists**, pushed by a PAT or from a laptop | One-time manual link, below. Until then every push 403s. |

**Do not "initialize" a new package by hand.** Pushing from the CLI does *not*
link the package to any repository, even when the name matches — so
pre-creating one manufactures exactly the broken state you are trying to avoid.
The only correct way to create a package here is to let the workflow do it.

There is no settings page for a package that does not exist, so a 404 on that
URL means the package has not been created yet — which is the good case.

#### Which case am I in?

GHCR's token endpoint distinguishes them without any credentials:

```sh
curl -s "https://ghcr.io/token?scope=repository%3Akrammygod%2F<pkg>%3Apull&service=ghcr.io"
```

`UNAUTHORIZED` means it exists and needs linking. `DENIED` means it does not
exist and needs nothing.

#### Linking an existing package

Per package, once. There is no REST API for this — the UI is the only route:

1. Profile → **Packages** tab → click the package.
2. **Package settings** (gear, right-hand side).
3. Under **Manage Actions access**, click **Add repository**, pick the calling
   repo, and set the role to **Write**.

Every image *and* the `-dev` variant needs it, so a two-image repo means four:
`example-app`, `example-app-dev`, `example-worker`, `example-worker-dev`.

The symptom when it is missing is a push failure that looks like a credential
problem but is not:

```
failed to push ghcr.io/krammygod/example-app-dev:src-...: unexpected status from
HEAD request to https://ghcr.io/v2/.../blobs/sha256:...: 403 Forbidden
```

The `<ns>-manifests` package never needs this, because nothing has ever pushed
one — it is always created by the workflow.

### 4. Add the cluster entry

In the infrastructure repo's Flux config — an `OCIRepository` and a
`Kustomization`. Until it exists, CI goes green and nothing deploys.

Do this **after** the first successful publish, and confirm the artifact is
really there first:

```sh
docker manifest inspect ghcr.io/krammygod/<namespace>-manifests:main
```

A `DENIED: denied` from GHCR means the package does not exist. An existing
package you cannot read answers `UNAUTHORIZED` instead — the two are worth
telling apart before blaming a credential.

### Prerequisites, once

This repository is public, so any caller can resolve the workflow and no
Actions access setting is needed. If you fork it private, note that private
repos do not share workflows by default — **Settings → Actions → Access** has
to be opened up before callers can resolve it.

## Releases

Callers pin `@v1`, and `v1` is an **alias that moves**. Every push to main whose
commits warrant a release tags a new `vX.Y.Z` and force-moves `vX` onto it, so
consumers get fixes without re-pinning. Nothing is manual.

The bump comes from the commit messages since the last `vX.Y.Z` tag:

| Commit | Bump |
|---|---|
| `feat!:`, `fix(scope)!:`, or a `BREAKING CHANGE:` footer | major |
| `feat:` | minor |
| `fix:` `perf:` `refactor:` `revert:` `build:` `ci:` | patch |
| `docs:` `chore:` `style:` `test:`, or anything unconventional | none — no release |

Highest wins across the whole range. `ci:` counts because the shipped workflows
*are* the product here; in an app repo it would be noise.

A push where nothing qualifies tags nothing and says so. That is the normal
outcome for a docs commit, and it is why `@v1` does not churn.

### Cutting v2

Land a commit marked breaking. The release then tags `v2.0.0` and creates a
**new** `v2` alias, leaving `v1` frozen at the last `v1.x.x` — so every existing
caller keeps working on the old contract until it edits its `uses:` line. That
freeze is the whole reason the aliases are per-major.

### Forcing a release

**Actions → Release → Run workflow**, with `bump` set to `patch`, `minor` or
`major`. It skips reading the commits entirely — for releasing a docs-only fix
that `auto` would ignore, or cutting v2 deliberately without a `!` commit.

### Where the gate is

`release.yml` runs the full test suite before it tags, because tagging is what
reaches consumers. `test.yml` therefore runs on **pull requests only** — having
both fire on main would run the same suite twice per push.

## Known limits

- **A failed deploy does not mark the commit.** CI goes green when the artifact
  is pushed. Whether it applied is only visible in the cluster
  (`kubectl -n flux-system get kustomizations`). Recovering this means running
  Flux's notification-controller and giving it a GitHub token.
- **No per-PR environments.** A throwaway environment per pull request would need
  CI to create an `OCIRepository` and a `Kustomization` in the cluster, and CI
  deliberately can no longer write there. What `pr_overlay` gives instead is a
  single STANDING pull-request environment: every PR publishes to the same
  `<namespace>-dev` artifact, so a second open PR overwrites the first, and after
  a merge the environment is simply left running rather than torn down. The
  cluster objects for it are created once, by hand, alongside the production
  ones.
- `-dev` images accumulate in GHCR, as do per-commit manifest artifacts. Use a
  GHCR retention policy.
- Rollback is a cluster-side operation — patch the `OCIRepository` onto an older
  `:<sha>`. Content tags make the previous image easy to identify.
- The cluster still needs a read-only PAT, stored as an image pull secret, to
  pull the manifest artifact. It is not GitHub Actions, so it has no
  `GITHUB_TOKEN`. That is one secret for the whole system rather than one per
  repo.

## Tests

```sh
bash tests/run-all.sh
```

Needs `kubectl` (for the bundled Kustomize), `git`, `jq` and PyYAML. The shell
the workflows delegate to is covered by real tests, with `kubectl` and `flux`
stubbed; the workflow YAML is checked structurally.
