#!/usr/bin/env python3
"""No-secret fixtures for the native signal, reserved guest and release guard."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("admission", ROOT / "runner/kvm-admission.py")
admission = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admission)
snapshot = json.loads((ROOT / "tests/fixtures/merge-queue-hesperus.json").read_text())
entries = snapshot["data"]["repository"]["mergeQueue"]["entries"]["nodes"]


class AdmissionTests(unittest.TestCase):
    def test_optional_source_and_existing_control_pool_have_no_required_dependency(self):
        script = '''document=Psych.parse_file(ARGV[0]).to_ruby; puts JSON.generate(document)'''
        workflow = json.loads(subprocess.check_output(["ruby", "-rpsych", "-rjson", "-e", script,
                                                       str(ROOT / ".github/workflows/merge-intake.yml")], text=True))
        self.assertEqual(workflow["permissions"], {})
        self.assertEqual(list((workflow.get("on") or workflow["true"])), ["workflow_call"])
        self.assertEqual(workflow["concurrency"], {"group": "local-merge-intake-${{ github.repository }}", "cancel-in-progress": True})
        self.assertEqual(list(workflow["jobs"]), ["signal"])
        self.assertEqual(workflow["jobs"]["signal"]["name"], admission.SOURCE_SIGNAL_NAME)
        self.assertFalse(any("uses" in step for step in workflow["jobs"]["signal"]["steps"]))
        control = tomllib.loads((ROOT / "runner/runscaler-intake.toml").read_text())
        self.assertEqual((control["min-runners"], control["max-runners"], control["concurrent"]), (1, 1, 1))
        self.assertEqual(control["runner-image"], admission.CONTROL_IMAGE)
        self.assertEqual((control["docker"]["daemon-mode"], control["docker"]["dind"], control["docker"]["cache-volumes"]), ("none", False, []))

    def capacity_fixture(self):
        containers = {}
        processes = []
        membership = {}
        for slot in range(1, 5):
            name = f"linux-ephemeral-ci-linux-01-{slot}-123"
            identity = str(slot) * 64
            containers[name] = {"Id": identity}
            processes.append(f"{slot} Runner.Listener")
            membership[str(slot)] = identity
        name = "runner-1234abcd"
        identity = "c" * 64
        containers[name] = {"Id": identity, "Config": {"Image": admission.CONTROL_IMAGE, "Labels": {"managed-by": "runner"}},
                            "HostConfig": {"Privileged": False, "NanoCpus": 10**9, "CpuQuota": 0, "CpuPeriod": 0,
                                           "Memory": 1024**3, "NetworkMode": "hesperus-runscaler-pilot"}, "Mounts": []}
        processes += ["5 Runner.Listener", "6 Runner.Worker"]
        membership.update({"5": identity, "6": identity})
        def run(args):
            if args[0] == "ps":
                return "\n".join(processes)
            if args[0] == "systemctl":
                return "0"
            if args[1] == "ps":
                return "\n".join(containers)
            return json.dumps([containers[args[-1]]])
        return containers, processes, membership, run

    def test_control_worker_is_distinct_from_four_reserved_release_workers(self):
        containers, processes, membership, run = self.capacity_fixture()
        self.assertTrue(admission.capacity(run, "MemAvailable: 12000000 kB\n", membership.__getitem__)["release_slots_preserved"])
        processes.append("7 Runner.Worker")
        membership["7"] = "1" * 64
        with self.assertRaises(admission.routing.Refused):
            admission.capacity(run, "MemAvailable: 12000000 kB\n", membership.__getitem__)

    def test_another_guest_or_unbounded_control_cannot_borrow_the_slot(self):
        for mutation in ("guest", "mount", "memory", "listener", "headroom"):
            containers, processes, membership, run = self.capacity_fixture()
            memory = "MemAvailable: 12000000 kB\n"
            if mutation == "guest":
                processes.append("20 qemu-system-x86")
            elif mutation == "mount":
                containers["runner-1234abcd"]["Mounts"] = [{"Source": "/var/run/docker.sock"}]
            elif mutation == "memory":
                containers["runner-1234abcd"]["HostConfig"]["Memory"] = 0
            elif mutation == "listener":
                processes.pop(0)
            else:
                memory = "MemAvailable: 1000 kB\n"
            with self.subTest(mutation=mutation), self.assertRaises(admission.routing.Refused):
                admission.capacity(run, memory, membership.__getitem__)

    def test_only_successful_completed_control_message_wakes_admission(self):
        hint = {"prefix": "hesperus-runscaler-pc", "msg": "Runner removed", "reason": "job-completed", "result": "succeeded",
                "job": admission.SIGNAL_NAME, "repo": "autumngarage/hesperus", "workflowRunId": 1}
        self.assertEqual(admission.signal_hint(json.dumps(hint)), ("autumngarage/hesperus", 1))
        for patching in ({"result": "canceled"}, {"reason": "unknown"}, {"job": "validate"}):
            self.assertIsNone(admission.signal_hint(json.dumps(dict(hint, **patching))))

    def test_multiple_or_fragmented_control_events_do_not_wait_for_another_log_line(self):
        reader, writer = os.pipe()
        try:
            with os.fdopen(reader, "rb", buffering=0) as stream:
                os.write(writer, b'first\nsecond\npar')
                lines, buffered, eof = admission.control_lines(stream, b"")
                self.assertEqual((lines, buffered, eof), (["first", "second"], b"par", False))
                os.write(writer, b'tial\n')
                self.assertEqual(admission.control_lines(stream, buffered), (["partial"], b"", False))
        finally:
            os.close(writer)

    def request_fixture(self):
        repository = "autumngarage/hesperus"
        policy = copy.deepcopy(admission.routing.POLICY[repository])
        policy["issuer"] = {"app_id": 10, "creator_id": 20, "creator_login": "fixture[bot]", "creator_type": "Bot"}
        base, head = entries[0]["baseCommit"]["oid"], entries[1]["headCommit"]["oid"]
        repo = {"id": policy["repository_id"], "full_name": repository, "private": True}
        source = "f" * 40
        config = {"repository": repository, "signal_source_sha": source, "signal_workflow_id": 11, "control_group_id": 14,
                  "control_label": "hesperus-runscaler-pc", "routine_group_id": 99,
                  "validation_source_ref": "autumngarage/touchstone-workflows/.github/workflows/validate.yml@refs/heads/main",
                  "validation_source_sha": source}
        signal = {"id": 1, "repository": repo, "event": "merge_group", "workflow_id": 11,
                  "path": ".github/workflows/local-merge-intake.yml", "status": "completed", "conclusion": "success",
                  "run_attempt": 1, "head_sha": head, "referenced_workflows": [{"path":
                      "autumngarage/touchstone-workflows/.github/workflows/merge-intake.yml@" + source, "sha": source}]}
        control = {"name": admission.SIGNAL_NAME, "head_sha": head, "run_id": 1, "run_attempt": 1,
                   "status": "completed", "conclusion": "success", "runner_group_id": 14, "runner_id": 500,
                   "labels": [config["control_label"]]}
        native = {"id": 2, "run_attempt": 3, "repository": repo, "event": "merge_group", "status": "in_progress",
                  "workflow_id": policy["workflow_id"], "path": ".github/workflows/validate.yml", "referenced_workflows": [],
                  "head_sha": head, "head_branch": "gh-readonly-queue/main/pr-4270-" + base}
        class API:
            def __init__(inner):
                inner.signal, inner.control, inner.native = signal, control, native
                inner.jobs = []
                inner.rules = [{"parameters": {"workflows": [{"path": ".github/workflows/validate.yml", "ref": "refs/heads/main",
                                                               "sha": source, "repository_id": admission.SOURCE_REPOSITORY_ID}]}}]
            def call(inner, path, payload=None):
                if path.endswith("/actions/runs/1"):
                    return inner.signal
                if "/runs/1/attempts/" in path:
                    return {"total_count": 1, "jobs": [inner.control]}
                if "/rules/branches/" in path:
                    return inner.rules
                if "/actions/runs?" in path:
                    return {"total_count": 1, "workflow_runs": [inner.native]}
                if path.endswith("/actions/runs/2"):
                    return inner.native
                if "/runs/2/attempts/" in path:
                    return {"total_count": len(inner.jobs), "jobs": inner.jobs}
                if "/runner-groups/" in path:
                    return {"visibility": "selected", "allows_public_repositories": False,
                            "restricted_to_workflows": True, "selected_workflows": [
                                "autumngarage/touchstone-workflows/.github/workflows/merge-intake.yml@" + source
                                if path.endswith("/14") else config["validation_source_ref"]]}
                raise AssertionError(path)
            def queue(inner, repository, branch):
                return snapshot
        return repository, policy, config, API()

    def test_hint_cannot_authorize_a_different_attempt_source_or_already_assigned_job(self):
        repository, policy, config, api = self.request_fixture()
        with patch.dict(admission.routing.POLICY, {repository: policy}):
            request = admission.authoritative_request(api, api, (repository, 1), config)
            self.assertEqual((request["run_id"], request["attempt"]), (2, 3))
            # Job completion reaches the scale-set stream before the workflow
            # run's finalization; native hosted allocation can still be queued.
            api.signal.update(status="in_progress", conclusion=None)
            api.native["status"] = "queued"
            self.assertEqual(admission.authoritative_request(api, api, (repository, 1), config), request)
            api.signal.update(status="completed", conclusion="success")
            api.native["status"] = "in_progress"
            api.control["run_attempt"] = 2
            with self.assertRaises(admission.routing.Refused):
                admission.authoritative_request(api, api, (repository, 1), config)
            api.control["run_attempt"] = 1
            api.jobs = [{"name": "validate-groups (checks, checks)", "status": "queued"}]
            with self.assertRaises(admission.routing.Refused):
                admission.authoritative_request(api, api, (repository, 1), config)
            api.jobs = []
            api.rules[0]["parameters"]["workflows"][0]["sha"] = "a" * 40
            with self.assertRaises(admission.routing.Refused):
                admission.authoritative_request(api, api, (repository, 1), config)
            api.rules[0]["parameters"]["workflows"][0]["sha"] = config["validation_source_sha"]
            api.signal["referenced_workflows"][0]["sha"] = "a" * 40
            with self.assertRaises(admission.routing.Refused):
                admission.authoritative_request(api, api, (repository, 1), config)

    def test_interrupted_registration_checkpoint_keeps_recoverable_original_lease(self):
        repository, policy, config, api = self.request_fixture()
        with patch.dict(admission.routing.POLICY, {repository: policy}), tempfile.TemporaryDirectory() as directory:
            request = admission.authoritative_request(api, api, (repository, 1), config)
            config["state_dir"] = directory
            reservation = admission.routing.reserve(directory, request, "pc-kvm")["reservation"]
            path = admission.reservation_file(config, reservation)
            with patch.object(Path, "replace", side_effect=OSError("interrupted checkpoint")), self.assertRaises(OSError):
                admission.checkpoint_registration(config, dict(reservation, runner_id=789))
            self.assertEqual(json.loads(path.read_text()), reservation)

    def test_optional_signal_must_not_become_a_required_workflow_or_status(self):
        repository, policy, config, api = self.request_fixture()
        with patch.dict(admission.routing.POLICY, {repository: policy}):
            for rules in ([{"parameters": {"workflows": [{"path": ".github/workflows/merge-intake.yml"}]}}],
                          [{"parameters": {"required_status_checks": [{"context": admission.SIGNAL_NAME}]}}]):
                api.rules = rules
                with self.assertRaises(admission.routing.Refused):
                    admission.authoritative_request(api, api, (repository, 1), config)

    def test_delayed_assignment_holds_guest_and_different_selector_reclaims_only_owned_guest(self):
        repository, policy, config, api = self.request_fixture()
        with patch.dict(admission.routing.POLICY, {repository: policy}), tempfile.TemporaryDirectory() as directory:
            request = admission.authoritative_request(api, api, (repository, 1), config)
            config["state_dir"] = directory
            reservation = admission.routing.reserve(directory, request, "pc-kvm")["reservation"]
            reservation["runner_id"] = 789
            path = admission.reservation_file(config, reservation)
            path.write_text(json.dumps(reservation))
            api.jobs = [{"name": "validate-groups (checks, checks)", "status": "queued", "labels": [
                "self-hosted", "linux-kvm-x64-checks", admission.routing.runner_label(request)]}]
            calls = []
            class Registration:
                def call(inner, endpoint, payload=None, method=None):
                    calls.append((endpoint, method))
            with patch.object(admission.subprocess, "run") as systemctl, patch.object(admission, "command", return_value="0"):
                self.assertFalse(admission.reconcile(api, Registration(), config, reservation))
                self.assertEqual(calls, [])
                systemctl.assert_not_called()
                api.jobs[0]["labels"] = ["ubuntu-latest"]
                self.assertTrue(admission.reconcile(api, Registration(), config, reservation))
                self.assertEqual(calls, [("/orgs/autumngarage/actions/runners/789", "DELETE")])
                self.assertEqual(systemctl.call_args.args[0], ["sudo", "-n", "systemctl", "stop", admission.UNIT])
                self.assertFalse(path.exists())

    def test_failed_guest_teardown_retains_reservation_and_installation_dry_run_has_no_effects(self):
        repository, policy, config, api = self.request_fixture()
        with patch.dict(admission.routing.POLICY, {repository: policy}), tempfile.TemporaryDirectory() as directory:
            request = admission.authoritative_request(api, api, (repository, 1), config)
            config["state_dir"] = directory
            reservation = admission.routing.reserve(directory, request, "pc-kvm")["reservation"]
            reservation["runner_id"] = 789
            path = admission.reservation_file(config, reservation)
            path.write_text(json.dumps(reservation))
            api.jobs = [{"name": "validate-groups (checks, checks)", "status": "completed"}]
            class Registration:
                def call(inner, endpoint, payload=None, method=None):
                    return None
            with patch.object(admission.subprocess, "run"), patch.object(admission, "command", return_value="99"):
                with self.assertRaises(admission.routing.Refused):
                    admission.reconcile(api, Registration(), config, reservation)
            self.assertTrue(path.exists())
            with patch.object(admission.subprocess, "run") as mutate, self.assertRaises(admission.routing.Refused):
                admission.prepare(config)
            mutate.assert_not_called()
            with patch.object(admission.subprocess, "run") as mutate:
                plan = admission.installation_plan(config)
                self.assertFalse(plan["changes"])
                self.assertFalse(plan["release_service_changed"])
                self.assertTrue(all("/hesperus-runner.service" not in file["target"] for file in plan["files"]))
                mutate.assert_not_called()
            with patch.dict(admission.routing.POLICY, {repository: dict(policy, issuer=None)}), self.assertRaises(admission.routing.Refused):
                admission.activation_check(config)


if __name__ == "__main__":
    unittest.main()
