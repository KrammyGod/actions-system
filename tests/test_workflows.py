"""Structure of the shipped workflow and actions.

These cannot be executed without a registry, so what is asserted here is the
contract callers depend on: input names, defaults, the job graph, and the
condition that decides whether an artifact is published at all.
"""
import os
import sys

import yaml

failures = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n       {detail}", file=sys.stderr)
        failures.append(name)


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


# PyYAML parses the bare `on:` key as the boolean True.
ON = True

deploy = load(".github/workflows/deploy.yml")
call = deploy[ON]["workflow_call"]

want_inputs = {"namespace", "images", "registry", "kustomize_dir", "overlay", "runner"}
check("deploy.yml declares exactly the documented inputs",
      set(call["inputs"]) == want_inputs,
      set(call["inputs"]) ^ want_inputs)

check("namespace and images are required",
      {k for k, v in call["inputs"].items() if v.get("required")} == {"namespace", "images"},
      {k for k, v in call["inputs"].items() if v.get("required")})

defaults = {
    "registry": "ghcr.io/krammygod",
    "kustomize_dir": "kustomize",
    "overlay": "overlays/prod",
    "runner": "ubuntu-24.04-arm",
}
for key, value in defaults.items():
    check(f"default {key} == {value!r}",
          call["inputs"][key].get("default") == value,
          call["inputs"][key].get("default"))

with open(".github/workflows/deploy.yml", encoding="utf-8") as fh:
    body = fh.read()

# GITHUB_TOKEN, not a PAT. A reusable workflow only ever sees the CALLER's
# secrets, so a PAT meant one stored per consuming repo, each expiring on its
# own schedule. GITHUB_TOKEN needs no storage and cannot go stale.
check("the workflow requires no secrets", "secrets" not in call, list(call))
check("no PAT is referenced anywhere", "GHCR_PAT" not in body)
check("both registry logins use GITHUB_TOKEN",
      body.count("password: ${{ secrets.GITHUB_TOKEN }}") == 2,
      body.count("password: ${{ secrets.GITHUB_TOKEN }}"))

jobs = deploy["jobs"]

# A called workflow can only downgrade the caller's GITHUB_TOKEN. Declaring the
# requirement makes a caller that forgets `packages: write` fail at validation,
# naming the permission, rather than 403-ing inside a docker push.
for name in ("build", "publish"):
    check(f"{name} declares the packages:write it needs",
          jobs[name]["permissions"] == {"contents": "read", "packages": "write"},
          jobs[name].get("permissions"))
check("checksum asks for no more than it needs",
      jobs["checksum"]["permissions"] == {"contents": "read"},
      jobs["checksum"].get("permissions"))
check("job graph is checksum -> build -> publish",
      set(jobs) == {"checksum", "build", "publish"}
      and jobs["build"]["needs"] == ["checksum"]
      and set(jobs["publish"]["needs"]) == {"checksum", "build"},
      list(jobs))

check("build matrix fans out over images",
      jobs["build"]["strategy"]["matrix"]["image"] == "${{ fromJSON(inputs.images) }}")

check("one broken image does not hide the others",
      jobs["build"]["strategy"]["fail-fast"] is False)

# The whole reason for the Flux migration: no job may need a runner that can
# reach the cluster, because no job reaches the cluster. A `runs-on` that is not
# the caller-supplied input is a regression back to the push model.
for name, job in jobs.items():
    check(f"{name} runs on the caller's GitHub-hosted runner",
          job["runs-on"] == "${{ inputs.runner }}", job["runs-on"])

check("nothing is pinned to a self-hosted runner", "self-hosted" not in body)
check("no job carries a kubeconfig", "KUBECONFIG" not in body)

# publish is deliberately ungated so a pull request still renders its manifests
# — the cheapest place to catch a broken overlay. Only the push is conditional.
check("publish runs on every event", "if" not in jobs["publish"])

publish_step = [s for s in jobs["publish"]["steps"] if s.get("name") == "Publish manifests"][0]
gate = publish_step["with"]["push"]
check("the artifact is pushed only from main or a manual dispatch",
      "refs/heads/main" in gate and "workflow_dispatch" in gate, gate)
check("a pull request never pushes an artifact",
      "pull_request" not in gate, gate)

# The cluster-side OCIRepository builds this same string by hand. It is derived
# rather than configurable so the two cannot drift apart.
check("the artifact repository is derived from registry and namespace",
      publish_step["with"]["artifact"]
      == "oci://${{ inputs.registry }}/${{ inputs.namespace }}-manifests",
      publish_step["with"]["artifact"])

# Composite actions.
ck = load(".github/actions/checksum/action.yml")
check("checksum action is composite", ck["runs"]["using"] == "composite")
check("checksum exposes tags and pins", set(ck["outputs"]) == {"tags", "pins"},
      set(ck["outputs"]))
check("checksum takes images, registry and dev-suffix",
      set(ck["inputs"]) == {"images", "registry", "dev-suffix"}, set(ck["inputs"]))

pb = load(".github/actions/publish/action.yml")
check("publish is composite", pb["runs"]["using"] == "composite")
want_pb = {"pins", "namespace", "artifact", "push", "tag", "kustomize-dir", "overlay"}
check("publish declares the documented inputs",
      set(pb["inputs"]) == want_pb, set(pb["inputs"]) ^ want_pb)
check("publish requires pins, namespace and artifact",
      {k for k, v in pb["inputs"].items() if v.get("required")}
      == {"pins", "namespace", "artifact"},
      {k for k, v in pb["inputs"].items() if v.get("required")})
check("publish defaults to not pushing",
      pb["inputs"]["push"]["default"] == "false", pb["inputs"]["push"]["default"])
check("publish defaults to the moving tag the cluster follows",
      pb["inputs"]["tag"]["default"] == "main", pb["inputs"]["tag"]["default"])


# Both run: blocks are deliberately a single `bash "$SCRIPT"`. The logic lives
# in the .sh files beside them, where shellcheck can see it and where
# tests/test-compute-tags.sh and tests/test-publish.sh execute it for real.
#
# What stood here before was a set of substring matches against those run:
# bodies — checks that passed whether or not the code worked. Behaviour is
# asserted in those two suites now; all that is asserted here is that the glue
# stayed thin, because a run: block that grows a second statement is logic no
# test can reach.
def sole_invocation(action):
    """The single non-comment line of the step's run:, or None if there is more."""
    run = action["runs"]["steps"][0]["run"]
    lines = [l.strip() for l in run.splitlines()
             if l.strip() and not l.lstrip().startswith("#")]
    return lines[0] if len(lines) == 1 else None


def shipped_script(action, directory):
    """On-disk path of the script the step's SCRIPT env points at."""
    src = action["runs"]["steps"][0]["env"]["SCRIPT"]
    return os.path.join(directory, src.rsplit("/", 1)[-1])


for label, action, directory in (
    ("checksum", ck, ".github/actions/checksum"),
    ("publish", pb, ".github/actions/publish"),
):
    check(f"{label} run: only invokes its script",
          sole_invocation(action) == 'bash "$SCRIPT"',
          sole_invocation(action))
    # Catches a renamed action directory or script, which otherwise surfaces
    # only once the workflow runs.
    check(f"{label} ships the script it invokes",
          os.path.isfile(shipped_script(action, directory)),
          shipped_script(action, directory))

# PR namespaces needed a cluster write to create and another to tear down.
# Under the pull model CI cannot do either, so the whole path is gone rather
# than half-present.
check("no PR-environment machinery survives",
      not os.path.exists(".github/workflows/cleanup.yml")
      and "deploy_on_pr" not in body and "-pr-" not in body)

print()
if failures:
    print(f"{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("all workflow checks passed")
