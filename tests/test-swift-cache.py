#!/usr/bin/env python3
"""Exercise the protected workflow's actual cache-key shell and its wiring."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
workflow = json.loads(subprocess.check_output([
    "ruby", "-ryaml", "-rjson", "-e", "puts YAML.load_file(ARGV[0]).to_json",
    str(root / ".github/workflows/validate.yml"),
], text=True))
assert "workflow_call" in workflow.get("on", workflow.get("true", {}))
plan = next(s for s in workflow["jobs"]["plan"]["steps"] if s.get("id") == "plan")
assert plan["env"]["EVENT_NAME"] == "${{ github.event_name }}"
steps = workflow["jobs"]["validate-groups"]["steps"]
key = next(s for s in steps if s.get("id") == "swift-cache")
cache = next(s for s in steps if s.get("name") == "Restore Swift build cache")
save = next(s for s in steps if s.get("name") == "Save default-branch Swift build cache")
check = next(s for s in steps if s.get("name") == "Verify cached toolchain stayed in force")
validate = next(s for s in steps if s.get("name") == "Run declared validation")
prepare = next(s for s in steps if s.get("name") == "Prepare declared validation setup")
fetch = next(s for s in steps if s.get("name") == "Fetch pinned Touchstone validator")
assert key["if"] == "vars.SWIFT_BUILD_CACHE == 'true' && runner.os == 'Linux' && hashFiles('Package.resolved') != ''"
assert prepare["if"] == key["if"], "only opted-in Linux cache consumers prepare twice"
assert prepare["env"] == {"VALIDATION_GROUP": "${{ matrix.group }}"}
assert key["env"]["CACHE_GRAPH"] == "${{ hashFiles('**/Package.swift', '**/Package.resolved', '.swift-version', '.touchstone.toml', 'scripts/ci-setup-swift.sh', 'scripts/swift-check.sh') }}"
assert key["env"]["CACHE_OS"] == "${{ runner.os }}"
assert key["env"]["CACHE_ARCH"] == "${{ runner.arch }}"
assert key["env"]["CACHE_REVISION"] == "${{ github.sha }}"
assert cache["uses"] == "actions/cache/restore@0057852bfaa89a56745cba8c7296529d2fc39830"
assert cache["id"] == "restore-swift-cache"
assert save["uses"] == "actions/cache/save@0057852bfaa89a56745cba8c7296529d2fc39830"
assert save["if"] == "success() && matrix.group == '' && steps.swift-cache.outputs.save == 'true' && steps.restore-swift-cache.outputs.cache-hit != 'true'"
assert save["with"] == {"path": ".build", "key": "${{ steps.swift-cache.outputs.key }}"}
assert key["env"]["CACHE_EVENT"] == "${{ github.event_name }}"
assert key["env"]["CACHE_REF"] == "${{ github.ref }}"
assert key["env"]["CACHE_DEFAULT_BRANCH"] == "${{ github.event.repository.default_branch }}"
assert cache["if"] == check["if"] == "steps.swift-cache.outputs.enabled == 'true'"
# AUT-3412: the retired Linux fleet's job-image cache is gone with it.
assert not any(s.get("id") == "runner-swift-cache" or s.get("name") == "Record the Swift build cache key" for s in steps)
assert cache["with"] == {"path": ".build", "key": "${{ steps.swift-cache.outputs.key }}", "restore-keys": "${{ steps.swift-cache.outputs.prefix }}"}
assert check["env"] == {"EXPECTED_TOOLCHAIN": "${{ steps.swift-cache.outputs.toolchain }}"}
assert steps.index(fetch) < steps.index(prepare) < steps.index(key) < steps.index(cache) < steps.index(validate) < steps.index(check) < steps.index(save)
assert "if" not in validate, "a cache hit must never skip validation"
assert validate["env"]["TOUCHSTONE_SWIFT_CACHE_KEY"] == "${{ steps.swift-cache.outputs.key }}"
assert validate["env"]["TOUCHSTONE_SWIFT_CACHE_RESTORED_KEY"] == "${{ steps.restore-swift-cache.outputs.cache-matched-key }}"

with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    binary = directory / "bin"
    binary.mkdir()
    if sys.platform == "darwin":
        # BSD sha256sum lacks GNU's long options; use macOS's real checker.
        checksum = binary / "sha256sum"
        checksum.write_text('#!/bin/sh\nexec /usr/bin/shasum -a 256 "$@"\n')
        checksum.chmod(0o755)
    swift = binary / "swift"
    swift.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_SWIFT_VERSION"\n')
    swift.chmod(0o755)
    env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}", CACHE_OS="Linux", CACHE_ARCH="ARM64", CACHE_GRAPH="graph-a", CACHE_REVISION="head-a", TEST_SWIFT_VERSION="Swift 6.3.3", CACHE_EVENT="push", CACHE_REF="refs/heads/main", CACHE_DEFAULT_BRANCH="main")

    # Group inventory captured from the pinned engine's schema-3 contract
    # for checks/swift-a/swift-b tasks; exercise the actual workflow shell.
    groups = [{"name": name, "tasks": [name]} for name in ("checks", "swift-a", "swift-b")]
    validator = directory / "touchstone-run.sh"
    validator.write_text('#!/bin/sh\ncat "$PLAN_CONTRACT_FILE"\n')

    def plan_groups(event, contract):
        captured = directory / "contract.json"
        captured.write_text(json.dumps(contract))
        output = directory / "plan-output"
        output.write_text("")
        subprocess.run(["bash", "-c", plan["run"]], env=dict(
            os.environ, EVENT_NAME=event, RUNNER_TEMP=str(directory),
            GITHUB_WORKSPACE=str(directory), GITHUB_OUTPUT=str(output),
            PLAN_CONTRACT_FILE=str(captured)), check=True)
        return json.loads(dict(line.split("=", 1) for line in output.read_text().splitlines())["matrix"])

    serial = {"include": [{"name": "all", "group": ""}]}
    for event in ("push", "workflow_call", "workflow_dispatch"):
        assert plan_groups(event, {"schema": 3, "groups": groups}) == serial, event
    sharded = {"include": [{"name": group["name"], "group": group["name"]} for group in groups]}
    for event in ("pull_request", "merge_group"):
        assert plan_groups(event, {"schema": 3, "groups": groups}) == sharded, event
        for legacy in ({}, {"groups": []}):
            assert plan_groups(event, legacy) == serial, (event, legacy)

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
    for event, configured in (
        ("pull_request", "checks-b,checks"),
        ("merge_group", "checks,checks-b,swift-other"),
        ("schedule", "checks,checks-b"),
    ):
        skipped = identify(CACHE_EVENT=event, VALIDATION_GROUP="checks-b", CACHE_SKIP_GROUPS=configured)
        assert skipped == {}, (event, skipped)
    for configured in ("", "checks", "checks-b-extra", "extra-checks-b", "CHECKS-B", " checks-b"):
        assert identify(VALIDATION_GROUP="checks-b", CACHE_SKIP_GROUPS=configured) == baseline, configured
    for event in ("push", "workflow_dispatch"):
        assert identify(CACHE_EVENT=event, VALIDATION_GROUP="", CACHE_SKIP_GROUPS="checks-b,all,") == baseline
    assert key["env"]["CACHE_SKIP_GROUPS"] == "${{ vars.SWIFT_BUILD_CACHE_SKIP_GROUPS }}"
    assert key["env"]["VALIDATION_GROUP"] == prepare["env"]["VALIDATION_GROUP"]
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
    assert changed.returncode != 0 and "retain the prepared" in changed.stderr

    # Exercise the actual workflow shell at its engine transport boundary.
    # Production checksum literals are separately bound to the source manifest;
    # this isolated transport fixture substitutes only its own expected hash.
    selected_bin = directory / "selected-bin"
    selected_bin.mkdir()
    selected_swift = selected_bin / "swift"
    selected_swift.write_text('#!/bin/sh\nprintf "Swift 6.4.2\\n"\n')
    selected_swift.chmod(0o755)
    calls = directory / "engine-calls"
    task = directory / "task-ran"
    github_path = directory / "github-path"
    engine_fixture = '''#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >>"$ENGINE_CALLS"
case "$1" in
  prepare)
    if [ "${PREPARE_FAIL:-false}" = true ]; then exit 47; fi
    printf '%s\\n' "$SELECTED_BIN" >>"$GITHUB_PATH"
    if [ "${PREPARE_TAMPER:-false}" = true ]; then printf '# changed\\n' >>"$0"; fi
    ;;
  validate) touch "$TASK_MARKER" ;;
  *) exit 2 ;;
esac
'''
    fixture_hash = hashlib.sha256(engine_fixture.encode()).hexdigest()
    contract = json.loads((root / ".touchstone-source-contract.json").read_text())
    pinned_hash = contract["validationEngine"]["sha256"]
    assert validate["run"].count(f'touchstone_sha256="{pinned_hash}"') == 1
    validation_shell = validate["run"].replace(pinned_hash, fixture_hash)
    transport_env = dict(env, RUNNER_TEMP=str(directory), GITHUB_WORKSPACE=str(directory),
                         GITHUB_PATH=str(github_path), VALIDATION_GROUP="swift-a",
                         ENGINE_CALLS=str(calls), SELECTED_BIN=str(selected_bin), TASK_MARKER=str(task))

    validator.write_text(engine_fixture)
    subprocess.run(["bash", "-c", prepare["run"]], env=transport_env, check=True)
    assert not task.exists(), "preparation must not execute validation"
    assert "prepare --project" in calls.read_text() and "--group swift-a" in calls.read_text()
    prepared_env = dict(transport_env, PATH=f"{github_path.read_text().strip()}:{env['PATH']}")
    selected = identify(PATH=prepared_env["PATH"])
    assert selected["toolchain"] != baseline["toolchain"], "fingerprint must observe the compiler selected by preparation"
    subprocess.run(["bash", "-c", validation_shell], env=prepared_env, check=True)
    assert task.exists() and "validate --project" in calls.read_text()
    subprocess.run(["bash", "-c", check["run"]], env=dict(prepared_env, EXPECTED_TOOLCHAIN=selected["toolchain"]), check=True)

    task.unlink()
    without_cache = dict(transport_env, VALIDATION_GROUP="checks-b", CACHE_SKIP_GROUPS="checks-b")
    subprocess.run(["bash", "-c", prepare["run"]], env=without_cache, check=True)
    assert identify(VALIDATION_GROUP="checks-b", CACHE_SKIP_GROUPS="checks-b") == {}
    subprocess.run(["bash", "-c", validation_shell], env=without_cache, check=True)
    assert task.exists() and "--group checks-b" in calls.read_text()

    task.unlink()
    failed = subprocess.run(["bash", "-c", prepare["run"]], env=dict(transport_env, PREPARE_FAIL="true"), capture_output=True, text=True)
    assert failed.returncode == 47 and not task.exists(), "preparation failure must reach the workflow before restore/tasks"

    subprocess.run(["bash", "-c", prepare["run"]], env=dict(transport_env, PREPARE_TAMPER="true"), check=True)
    refused = subprocess.run(["bash", "-c", validation_shell], env=prepared_env, capture_output=True, text=True)
    assert refused.returncode != 0 and "FAILED" in refused.stdout and not task.exists(), "changed engine bytes must not execute validation"

    swift.rename(binary / "unused-swift")
    assert identify(PATH=str(binary)) == {}, "a missing toolchain must not enable restore/save"
print("Swift cache contract: compatible restores from GitHub's cache, validated default-branch writers, and no skipped validation")
