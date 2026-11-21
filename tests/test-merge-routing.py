#!/usr/bin/env python3
"""Behavioral fixtures for protected placement and exclusive local admission."""

import copy
import datetime
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_routing", ROOT / "runner/merge-routing.py")
routing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routing)
# Captured read-only from GitHub's Hesperus mergeQueue on 2026-11-21. Preserve
# its real consecutive candidate/base edges; do not infer origins from refs.
SNAPSHOT = json.loads((ROOT / "tests/fixtures/merge-queue-hesperus.json").read_text())
ENTRIES = SNAPSHOT["data"]["repository"]["mergeQueue"]["entries"]["nodes"]
NOW = 1795272000
ISSUER = {"creator_id": 1234, "creator_login": "fixture-ci-service", "creator_type": "User"}


def fixture():
    policy = copy.deepcopy(routing.POLICY["autumngarage/hesperus"])
    policy["issuer"] = ISSUER
    request = {"repository": "autumngarage/hesperus", "repository_id": policy["repository_id"],
               "workflow_id": policy["workflow_id"], "run_id": 44880000000, "attempt": 1,
               "head": ENTRIES[1]["headCommit"]["oid"], "base": ENTRIES[0]["baseCommit"]["oid"],
               "group": "checks", "capability": routing.CAPABILITY}
    ref = f'refs/heads/gh-readonly-queue/main/pr-4270-{request["base"]}'
    event = {"repository": {"id": request["repository_id"], "full_name": request["repository"], "private": True},
             "merge_group": {"base_ref": "refs/heads/main", "base_sha": request["base"], "head_sha": request["head"], "head_ref": ref}}
    run = {"id": request["run_id"], "run_attempt": 1, "repository": {"id": request["repository_id"]},
           "workflow_id": policy["workflow_id"], "event": "merge_group", "path": ".github/workflows/validate.yml",
           "referenced_workflows": [], "head_sha": request["head"], "head_branch": ref.removeprefix("refs/heads/"), "status": "in_progress"}
    status = {"id": 100, "context": routing.context(request), "state": "success", "target_url": routing.run_url(request),
              "description": f'v1;ttl=120;capability={routing.CAPABILITY};runner=789',
              "creator": {"id": ISSUER["creator_id"], "login": ISSUER["creator_login"], "type": ISSUER["creator_type"]},
              "created_at": datetime.datetime.fromtimestamp(NOW - 10, datetime.timezone.utc).isoformat()}
    return policy, request, event, run, status


def competing_reservation(state_dir, request, barrier, results):
    barrier.wait()
    try:
        results.put(routing.reserve(state_dir, request, "pc-checks", now=lambda: NOW)["acquired"])
    except routing.Refused:
        results.put(False)


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.policy, self.request, self.event, self.run, self.status = fixture()
        self.matrix = {"include": [{"name": "checks", "group": "checks"}, {"name": "swift", "group": "swift"}]}
        self.targets = {"checks": "github", "swift": "github"}

    def test_real_multi_entry_candidate_proves_every_origin(self):
        self.assertEqual(routing.trusted_chain(self.request, SNAPSHOT), [4270, 4214])

    def test_ancestor_origin_cannot_hide_behind_trusted_terminal_pr(self):
        for mutation in ("fork", "deleted", "public", "different_id", "cross_repository"):
            snapshot = copy.deepcopy(SNAPSHOT)
            pr = snapshot["data"]["repository"]["mergeQueue"]["entries"]["nodes"][0]["pullRequest"]
            if mutation == "fork":
                pr["headRepository"]["nameWithOwner"] = "other/hesperus"
            elif mutation == "deleted":
                pr["headRepository"] = None
            elif mutation == "public":
                pr["headRepository"]["isPrivate"] = False
            elif mutation == "different_id":
                pr["headRepository"]["databaseId"] += 1
            else:
                pr["isCrossRepository"] = True
            with self.subTest(mutation=mutation), self.assertRaises(routing.Refused):
                routing.trusted_chain(self.request, snapshot)

    def test_incomplete_ambiguous_or_rebuilt_queue_is_not_trusted(self):
        for mutation in ("page", "missing", "duplicate", "cycle", "empty"):
            snapshot = copy.deepcopy(SNAPSHOT)
            entries = snapshot["data"]["repository"]["mergeQueue"]["entries"]
            if mutation == "page":
                entries["pageInfo"]["hasNextPage"] = True
            elif mutation == "missing":
                entries["nodes"].pop(0)
            elif mutation == "duplicate":
                entries["nodes"].append(entries["nodes"][0])
            elif mutation == "cycle":
                entries["nodes"][0]["baseCommit"]["oid"] = self.request["head"]
            else:
                entries["nodes"] = []
            with self.subTest(mutation=mutation), self.assertRaises(routing.Refused):
                routing.trusted_chain(self.request, snapshot)

    def test_required_native_workflow_and_unique_qualified_group(self):
        self.assertEqual(routing.qualified_request(self.event, self.run, self.matrix, self.targets, self.policy), self.request)
        for key, value in (("workflow_id", 1), ("path", "other.yml"), ("event", "pull_request"),
                           ("head_sha", "a" * 40), ("referenced_workflows", [{}]), ("status", "completed")):
            run = dict(self.run, **{key: value})
            with self.subTest(key=key), self.assertRaises(routing.Refused):
                routing.qualified_request(self.event, run, self.matrix, self.targets, self.policy)
        self.matrix["include"].append({"name": "CHECKS", "group": "CHECKS"})
        with self.assertRaises(routing.Refused):
            routing.qualified_request(self.event, self.run, self.matrix, self.targets, self.policy)

    def test_only_fresh_bound_controller_acknowledgement_selects_one_guest(self):
        grant = routing.status_grant(self.request, [self.status], ISSUER, NOW)
        self.assertEqual(grant["group"], "checks")
        self.assertEqual(grant["labels"], ["self-hosted", "linux-kvm-x64-checks", routing.runner_label(self.request)])
        for key, value in (("state", "pending"), ("description", "busy"), ("context", "other"),
                           ("target_url", "https://example.test"), ("created_at", "2020-01-01T00:00:00Z"),
                           ("creator", {"id": 1}), ("description", f'v1;ttl=999;capability={routing.CAPABILITY};runner=789')):
            status = dict(self.status, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(routing.Refused):
                routing.status_grant(self.request, [status], ISSUER, NOW)
        for statuses, issuer, now in (([], ISSUER, NOW), ([self.status], None, NOW), ([self.status], ISSUER, NOW + 121), ([self.status], ISSUER, NOW - 20)):
            with self.assertRaises(routing.Refused):
                routing.status_grant(self.request, statuses, issuer, now)

    def test_latest_refusal_and_new_attempt_defeat_earlier_acknowledgement(self):
        with self.assertRaises(routing.Refused):
            routing.status_grant(self.request, [self.status, dict(self.status, id=101, state="failure")], ISSUER, NOW)
        with self.assertRaises(routing.Refused):
            routing.status_grant(dict(self.request, attempt=2), [self.status], ISSUER, NOW)
        self.assertNotEqual(routing.runner_label(self.request), routing.runner_label(dict(self.request, attempt=2)))

    def test_repeat_busy_draining_and_concurrent_reservations(self):
        with tempfile.TemporaryDirectory() as directory:
            first = routing.reserve(directory, self.request, "pc-checks", now=lambda: NOW)
            self.assertTrue(first["acquired"])
            repeat = routing.reserve(directory, self.request, "pc-checks", now=lambda: NOW + 200)
            self.assertFalse(repeat["acquired"])
            self.assertEqual(first["reservation"], repeat["reservation"])
            with self.assertRaises(routing.Refused):
                routing.reserve(directory, dict(self.request, run_id=2), "pc-checks")
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "draining").touch()
            with self.assertRaises(routing.Refused):
                routing.reserve(directory, self.request, "pc-checks")
        with tempfile.TemporaryDirectory() as directory:
            # Real independent processes contend for the same mkdir lock and slot.
            context = multiprocessing.get_context("fork")
            barrier, results = context.Barrier(2), context.Queue()
            children = [context.Process(target=competing_reservation,
                                        args=(directory, dict(self.request, run_id=number), barrier, results)) for number in (1, 2)]
            for child in children:
                child.start()
            for child in children:
                child.join(10)
                self.assertEqual(child.exitcode, 0)
            self.assertEqual(sorted([results.get(timeout=1), results.get(timeout=1)]), [False, True])

    def test_planner_reads_fresh_ack_after_bounded_intake_and_rechecks_chain(self):
        test = self

        class API:
            def __init__(inner):
                inner.calls = []
                inner.status = test.status
                inner.declaration = "d" * 40
                inner.final_snapshot = SNAPSHOT

            def call(inner, path, payload=None):
                inner.calls.append(path)
                if "/actions/runs/" in path:
                    return test.run
                if "/git/trees/" in path:
                    return {"truncated": False, "tree": [{"path": ".touchstone.toml", "type": "blob", "mode": "100644", "sha": inner.declaration}]}
                raise AssertionError(path)

            def queue(inner, repository, branch):
                inner.calls.append("queue")
                return inner.final_snapshot

            def statuses(inner, request):
                inner.calls.append("statuses")
                return [] if inner.status is None else [inner.status]

        with patch.dict(routing.POLICY, {self.request["repository"]: self.policy}), patch.dict(os.environ, {
            "GITHUB_RUN_ID": str(self.request["run_id"]), "GITHUB_RUN_ATTEMPT": "1",
        }):
            api = API()
            def pause(seconds):
                self.assertEqual(seconds, routing.ADMISSION_WINDOW)
                api.calls.append("bounded-wait")
            result = routing.plan(api, self.event, self.matrix, self.targets, now=lambda: NOW, pause=pause)
            self.assertEqual(result["runner_id"], 789)
            self.assertEqual(api.calls[-3:], ["bounded-wait", "statuses", "queue"])
            api.status = None
            with self.assertRaises(routing.Refused):
                routing.plan(api, self.event, self.matrix, self.targets, now=lambda: NOW, pause=pause)
            api.status = dict(self.status, created_at="2020-01-01T00:00:00Z")
            with self.assertRaises(routing.Refused):
                routing.plan(api, self.event, self.matrix, self.targets, now=lambda: NOW, pause=pause)
            self.policy["issuer"] = None
            api.calls.clear()
            with self.assertRaises(routing.Refused):
                routing.plan(api, self.event, self.matrix, self.targets, now=lambda: NOW, pause=pause)
            self.assertEqual(api.calls, [])

    def test_publication_requires_post_reservation_capacity_and_live_jit_ack(self):
        class API:
            def __init__(inner):
                inner.posted = []

            def call(inner, path, payload=None):
                if path == "/user":
                    return {"id": ISSUER["creator_id"], "login": ISSUER["creator_login"], "type": ISSUER["creator_type"]}
                if path.startswith("/orgs/"):
                    return {"id": 789, "status": "online", "busy": False,
                            "labels": [{"name": label} for label in ("self-hosted", "linux-kvm-x64-checks", routing.runner_label(self.request))]}
                inner.posted.append(payload)
                return payload

        reservation = {"request": self.request, "slot": "pc-checks", "reserved_at": NOW - 5}
        receipt = {"request": self.request, "slot": "pc-checks", "observed_at": NOW - 1, "isolation": "kvm",
                   "architecture": "x64", "guest_docker": True, "release_slots_preserved": True, "capacity_available": True,
                   "registration": "jit", "runner_id": 789}
        with patch.dict(routing.POLICY, {self.request["repository"]: self.policy}):
            api = API()
            routing.publish(api, reservation, receipt, ISSUER, now=lambda: NOW)
            self.assertEqual(api.posted[0]["context"], routing.context(self.request))
            for key, value in (("observed_at", NOW - 10), ("observed_at", NOW + 1), ("capacity_available", False),
                               ("isolation", "container"), ("guest_docker", False), ("release_slots_preserved", False), ("registration", "persistent")):
                with self.subTest(key=key), self.assertRaises(routing.Refused):
                    routing.publish(api, reservation, dict(receipt, **{key: value}), ISSUER, now=lambda: NOW)
            self.assertEqual(len(api.posted), 1)


if __name__ == "__main__":
    unittest.main()
