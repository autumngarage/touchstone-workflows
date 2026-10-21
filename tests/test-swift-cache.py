#!/usr/bin/env python3
"""Exercise the protected workflow's actual cache-key shell and its wiring."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
workflow = json.loads(subprocess.check_output([
    "ruby", "-ryaml", "-rjson", "-e", "puts YAML.load_file(ARGV[0]).to_json",
    str(root / ".github/workflows/validate.yml"),
], text=True))
assert "workflow_call" in workflow.get("on", workflow.get("true", {}))
steps = workflow["jobs"]["validate"]["steps"]
key = next(s for s in steps if s.get("id") == "swift-cache")
cache = next(s for s in steps if s.get("name") == "Restore Swift build cache")
save = next(s for s in steps if s.get("name") == "Save default-branch Swift build cache")
local = next(s for s in steps if s.get("id") == "runner-swift-cache")
record = next(s for s in steps if s.get("name") == "Record the Swift build cache key")
check = next(s for s in steps if s.get("name") == "Verify cached toolchain stayed in force")
validate = next(s for s in steps if s.get("name") == "Run declared validation")
assert key["if"] == "vars.SWIFT_BUILD_CACHE == 'true' && runner.os == 'Linux' && hashFiles('Package.resolved') != ''"
assert key["env"]["CACHE_GRAPH"] == "${{ hashFiles('**/Package.swift', '**/Package.resolved', '.touchstone.toml', 'scripts/ci-setup-swift.sh', 'scripts/swift-check.sh') }}"
assert key["env"]["CACHE_OS"] == "${{ runner.os }}"
assert key["env"]["CACHE_ARCH"] == "${{ runner.arch }}"
assert key["env"]["CACHE_REVISION"] == "${{ github.sha }}"
assert cache["uses"] == "actions/cache/restore@0057852bfaa89a56745cba8c7296529d2fc39830"
assert cache["id"] == "restore-swift-cache"
assert save["uses"] == "actions/cache/save@0057852bfaa89a56745cba8c7296529d2fc39830"
assert save["if"] == "success() && steps.swift-cache.outputs.save == 'true' && steps.restore-swift-cache.outputs.cache-hit != 'true'"
assert save["with"] == {"path": ".build", "key": "${{ steps.swift-cache.outputs.key }}"}
assert key["env"]["CACHE_EVENT"] == "${{ github.event_name }}"
assert key["env"]["CACHE_REF"] == "${{ github.ref }}"
assert key["env"]["CACHE_DEFAULT_BRANCH"] == "${{ github.event.repository.default_branch }}"
assert local["if"] == check["if"] == "steps.swift-cache.outputs.enabled == 'true'"
assert cache["if"] == "steps.swift-cache.outputs.enabled == 'true' && steps.runner-swift-cache.outputs.hit != 'true'"
assert local["env"] == {"CACHE_PREFIX": "${{ steps.swift-cache.outputs.prefix }}", "RUNNER_CACHE_ROOT": "/home/runner/swift-build-cache"}
assert record["if"] == "success() && steps.swift-cache.outputs.save == 'true'"
assert record["env"] == {"CACHE_KEY": "${{ steps.swift-cache.outputs.key }}", "CACHE_KEY_FILE": "/home/runner/.touchstone-swift-cache-key"}
# The supervisor that fills the image reads and writes the same two paths.
supervisor = (root / "runner/linux-runner.sh").read_text()
assert "\nCACHE_ROOT=/home/runner/swift-build-cache\n" in supervisor
assert "\nCACHE_KEY_FILE=/home/runner/.touchstone-swift-cache-key\n" in supervisor
assert cache["with"] == {"path": ".build", "key": "${{ steps.swift-cache.outputs.key }}", "restore-keys": "${{ steps.swift-cache.outputs.prefix }}"}
assert check["env"] == {"EXPECTED_TOOLCHAIN": "${{ steps.swift-cache.outputs.toolchain }}"}
assert steps.index(key) < steps.index(local) < steps.index(cache) < steps.index(validate) < steps.index(check) < steps.index(record) < steps.index(save)
assert "if" not in validate, "a cache hit must never skip validation"

with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    binary = directory / "bin"
    binary.mkdir()
    swift = binary / "swift"
    swift.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_SWIFT_VERSION"\n')
    swift.chmod(0o755)
    env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}", CACHE_OS="Linux", CACHE_ARCH="ARM64", CACHE_GRAPH="graph-a", CACHE_REVISION="head-a", TEST_SWIFT_VERSION="Swift 6.3.3", CACHE_EVENT="push", CACHE_REF="refs/heads/main", CACHE_DEFAULT_BRANCH="main")

    def identify(**changes):
        output = directory / "output"
        output.write_text("")
        subprocess.run(["/bin/bash", "-c", key["run"]], env=dict(env, GITHUB_OUTPUT=str(output), **changes), check=True)
        return dict(line.split("=", 1) for line in output.read_text().splitlines())

    baseline = identify()
    newer = identify(CACHE_REVISION="head-b")
    assert baseline["enabled"] == "true"
    assert baseline["prefix"] == newer["prefix"] and baseline["key"] != newer["key"]
    assert baseline["key"] == baseline["prefix"] + "head-a"
    assert baseline["save"] == "true"
    assert identify(CACHE_EVENT="workflow_dispatch")["save"] == "true"
    assert identify(CACHE_REF="refs/heads/trunk", CACHE_DEFAULT_BRANCH="trunk")["save"] == "true"
    for change in (
        {"CACHE_EVENT": "pull_request", "CACHE_REF": "refs/pull/56/merge"},
        {"CACHE_EVENT": "merge_group", "CACHE_REF": "refs/heads/gh-readonly-queue/main/pr-56"},
        {"CACHE_EVENT": "pull_request"},
        {"CACHE_EVENT": "merge_group"},
        {"CACHE_EVENT": "schedule"},
        {"CACHE_EVENT": "workflow_dispatch", "CACHE_REF": "refs/heads/topic"},
        {"CACHE_REF": "refs/heads/topic"},
        {"CACHE_REF": "refs/tags/main"},
        {"CACHE_DEFAULT_BRANCH": ""},
    ):
        selected = identify(**change)
        assert selected["save"] == "false" and selected["enabled"] == "true", change
    for change in ({"CACHE_GRAPH": "graph-b"}, {"CACHE_ARCH": "X64"}, {"CACHE_OS": "Other"}, {"TEST_SWIFT_VERSION": "Swift 6.4"}):
        assert identify(**change)["prefix"] != baseline["prefix"], change
    subprocess.run(["bash", "-c", check["run"]], env=dict(env, EXPECTED_TOOLCHAIN=baseline["toolchain"]), check=True)
    changed = subprocess.run(["bash", "-c", check["run"]], env=dict(env, EXPECTED_TOOLCHAIN=baseline["toolchain"], TEST_SWIFT_VERSION="Swift 6.4"), capture_output=True, text=True)
    assert changed.returncode != 0 and "retain the preinstalled" in changed.stderr

    # The runner's copy is taken only for this toolchain and package graph,
    # into a workspace that has no .build yet; anything else falls through
    # to GitHub's cache.
    def take(stored_key, workspace_has_build=False, products=True):
        runner_root = directory / "runner-cache"
        workspace = directory / "workspace"
        for path in (runner_root, workspace):
            subprocess.run(["rm", "-rf", str(path)], check=True)
        stored = runner_root / "autumngarage/hesperus"
        if products:
            (stored / ".build/debug").mkdir(parents=True)
            (stored / ".build/debug/product").write_text("built on main")
        else:
            stored.mkdir(parents=True)
        if stored_key is not None:
            (stored / ".touchstone-swift-cache-key").write_text(stored_key + "\n")
        workspace.mkdir()
        if workspace_has_build:
            (workspace / ".build").mkdir()
        output = directory / "output"
        output.write_text("")
        subprocess.run(["/bin/bash", "-c", local["run"]], cwd=workspace, check=True, env=dict(env,
            GITHUB_OUTPUT=str(output), GITHUB_REPOSITORY="autumngarage/hesperus",
            CACHE_PREFIX=baseline["prefix"], RUNNER_CACHE_ROOT=str(runner_root)))
        hit = output.read_text() == "hit=true\n"
        copied = (workspace / ".build/debug/product").is_file()
        assert hit == copied, (stored_key, hit, copied)
        return hit
    assert take(baseline["prefix"] + "older-main-head")
    assert not take(identify(CACHE_GRAPH="graph-b")["key"]), "another package graph"
    assert not take(identify(TEST_SWIFT_VERSION="Swift 6.4")["key"]), "another toolchain"
    assert not take(baseline["prefix"]), "a key with no revision"
    assert not take(None), "no recorded key"
    assert not take(baseline["key"], products=False), "a key without products"
    assert not take(baseline["key"], workspace_has_build=True), "a workspace that already has a .build"

    # Only a run that saves records its key, beside .build and never in it.
    def record_key(has_build=True, writable=True):
        workspace = directory / "seed"
        home = directory / "home"
        subprocess.run(["rm", "-rf", str(workspace), str(home)], check=True)
        workspace.mkdir()
        home.mkdir()
        if has_build:
            (workspace / ".build").mkdir()
        if not writable:
            home.chmod(0o555)
        key_file = home / ".touchstone-swift-cache-key"
        subprocess.run(["/bin/bash", "-c", record["run"]], cwd=workspace, check=True, env=dict(env,
            CACHE_KEY=baseline["key"], CACHE_KEY_FILE=str(key_file)))
        home.chmod(0o755)
        assert not list((workspace / ".build").iterdir()) if has_build else True
        return key_file.read_text() if key_file.exists() else None
    assert record_key() == baseline["key"] + "\n"
    assert record_key(has_build=False) is None
    assert record_key(writable=False) is None, "a runner whose home it cannot write is not an error"

    swift.rename(binary / "unused-swift")
    assert identify(PATH=str(binary)) == {}, "a missing toolchain must not enable restore/save"
print("Swift cache contract: compatible restores from GitHub or the runner's image, validated default-branch writers, and no skipped validation")
