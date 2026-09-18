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
assert cache["if"] == check["if"] == "steps.swift-cache.outputs.enabled == 'true'"
assert cache["with"] == {"path": ".build", "key": "${{ steps.swift-cache.outputs.key }}", "restore-keys": "${{ steps.swift-cache.outputs.prefix }}"}
assert check["env"] == {"EXPECTED_TOOLCHAIN": "${{ steps.swift-cache.outputs.toolchain }}"}
assert steps.index(key) < steps.index(cache) < steps.index(validate) < steps.index(check) < steps.index(save)
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
    swift.rename(binary / "unused-swift")
    assert identify(PATH=str(binary)) == {}, "a missing toolchain must not enable restore/save"
print("Swift cache contract: compatible restores, validated default-branch writers, and no skipped validation")
