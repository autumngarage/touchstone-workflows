#!/usr/bin/env python3
"""Protected merge placement and the existing supervisor's admission handoff.

This module never executes candidate code. The controller owns provisioning,
the exclusive slot reservation, and cleanup; GitHub owns job scheduling.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request


CAPABILITY = "linux-x64-kvm-guest-docker"
TTL = 120
ADMISSION_WINDOW = 20
MARKER = "touchstone/local"
# Qualification is committed with the protected workflow, never read from a
# candidate declaration or a mutable repository variable. Installation stays
# closed until the controller's service identity has been independently verified.
POLICY = {
    "autumngarage/hesperus": {
        "repository_id": 1350057617,
        "workflow_id": 345029816,
        "branch": "main",
        "group": "checks",
        "capability": CAPABILITY,
        "issuer": None,
    },
}


class Refused(Exception):
    """An unsupported or unproven placement keeps its existing hosted target."""


def require(condition, reason):
    if not condition:
        raise Refused(reason)


def sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value)


def integer(value):
    return type(value) is int and value > 0


def coordinates(request):
    names = ("repository_id", "workflow_id", "run_id", "attempt")
    require(all(integer(request.get(name)) for name in names), "invalid run coordinates")
    require(sha(request.get("head")) and sha(request.get("base")), "invalid candidate coordinates")
    require(re.fullmatch(r"[A-Za-z0-9._-]+", request.get("group", "")), "invalid group")
    return [str(request[name]) for name in names] + [request["group"]]


def context(request):
    parts = coordinates(request)
    return "/".join([MARKER] + parts[1:])


def runner_label(request):
    return "ts-merge-" + "-".join(coordinates(request))


def run_url(request):
    return f'https://github.com/{request["repository"]}/actions/runs/{request["run_id"]}/attempts/{request["attempt"]}'


def qualified_request(event, run, matrix, targets, policy):
    repo = event["repository"]
    merge = event["merge_group"]
    require(repo.get("private") is True and repo.get("id") == policy["repository_id"], "repository is not qualified")
    require(merge.get("base_ref") == "refs/heads/" + policy["branch"], "nondefault merge target")
    require(run.get("repository", {}).get("id") == repo["id"], "run repository differs")
    require(run.get("workflow_id") == policy["workflow_id"] and run.get("event") == "merge_group", "unqualified workflow")
    require(run.get("path") == ".github/workflows/validate.yml" and run.get("referenced_workflows") == [], "not the required native workflow")
    require(run.get("head_sha") == merge.get("head_sha") and run.get("head_branch") == merge.get("head_ref", "").removeprefix("refs/heads/"), "run candidate differs")
    require(run.get("status") == "in_progress", "run is no longer active")
    group = policy["group"]
    matches = [entry for entry in matrix["include"] if entry["name"].lower() == group.lower()]
    require(matches == [{"name": group, "group": group}] and targets.get(group) == "github", "group is not uniquely hosted")
    request = {
        "repository": repo["full_name"], "repository_id": repo["id"],
        "workflow_id": run["workflow_id"], "run_id": run["id"], "attempt": run["run_attempt"],
        "head": merge["head_sha"], "base": merge["base_sha"], "group": group,
        "capability": policy["capability"],
    }
    coordinates(request)
    return request


def trusted_chain(request, snapshot):
    """Follow GitHub's native queue edges, proving every contributing origin."""
    require(not snapshot.get("errors"), "queue query failed")
    repository = snapshot["data"]["repository"]
    require(repository["databaseId"] == request["repository_id"] and repository["isPrivate"] is True, "queue repository differs")
    entries = repository["mergeQueue"]["entries"]
    require(entries["pageInfo"]["hasNextPage"] is False, "queue census is incomplete")
    edges = {}
    for entry in entries["nodes"]:
        # Entries awaiting GitHub preparation have no candidate yet. They
        # cannot satisfy an edge in the candidate being assigned.
        if entry.get("headCommit") is None:
            continue
        head = entry["headCommit"]["oid"]
        require(head not in edges, "queue has ambiguous candidate edges")
        edges[head] = entry
    cursor, seen, numbers = request["head"], set(), []
    while cursor != request["base"]:
        require(cursor not in seen and cursor in edges, "queue candidate chain is incomplete")
        seen.add(cursor)
        edge = edges[cursor]
        pr = edge["pullRequest"]
        require(integer(pr["number"]) and sha(pr["headRefOid"]) and pr["isCrossRepository"] is False, "untrusted contributing pull request")
        for key in ("headRepository", "baseRepository"):
            origin = pr[key]
            require(origin and origin.get("databaseId") == request["repository_id"]
                    and origin.get("nameWithOwner") == request["repository"]
                    and origin.get("isPrivate") is True, "contributing origin is not the same private repository")
        numbers.append(pr["number"])
        cursor = edge["baseCommit"]["oid"]
        require(sha(cursor), "queue base is malformed")
    require(numbers and len(numbers) == len(set(numbers)), "empty or ambiguous contributing pull requests")
    return numbers


def status_grant(request, statuses, issuer, now):
    require(issuer and integer(issuer.get("creator_id")) and issuer.get("creator_login"), "no verified controller service identity")
    matches = [status for status in statuses if status.get("context") == context(request)]
    require(matches, "no local admission acknowledgement")
    # Status IDs are monotonic; an explicit later refusal must defeat a prior grant.
    require(all(integer(item.get("id")) for item in matches), "invalid status identity")
    status = max(matches, key=lambda item: item["id"])
    creator = status.get("creator") or {}
    require(creator.get("id") == issuer["creator_id"] and creator.get("login") == issuer["creator_login"]
            and creator.get("type") == issuer["creator_type"], "admission issuer differs")
    require(status.get("state") == "success" and status.get("target_url") == run_url(request), "local admission was not acknowledged")
    descriptor = rf'v1;ttl={TTL};capability={re.escape(request["capability"])};runner=([1-9][0-9]*)'
    match = re.fullmatch(descriptor, status.get("description") or "")
    require(match, "admission descriptor is invalid")
    issued = datetime.datetime.fromisoformat(status["created_at"].replace("Z", "+00:00")).timestamp()
    require(-5 <= now - issued <= TTL, "local admission is stale")
    return {"group": request["group"], "labels": ["self-hosted", "linux-kvm-x64-checks", runner_label(request)],
            "runner_id": int(match[1]), "status_id": status["id"]}


class GitHub:
    def __init__(self, token=None):
        self.token = token or os.environ["GH_TOKEN"]
        self.api = os.environ.get("GITHUB_API_URL", "https://api.github.com")

    def call(self, path, payload=None):
        url = self.api + path
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(url, data=data, headers={
            "Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json",
        })
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.load(response)

    def queue(self, repository, branch):
        owner, name = repository.split("/")
        return self.call("/graphql", {"query": """query($owner:String!,$name:String!,$branch:String!){
          repository(owner:$owner,name:$name){databaseId isPrivate
            mergeQueue(branch:$branch){entries(first:100){nodes{
              headCommit{oid} baseCommit{oid} pullRequest{number headRefOid isCrossRepository
                headRepository{databaseId nameWithOwner isPrivate}
                baseRepository{databaseId nameWithOwner isPrivate}}}
              pageInfo{hasNextPage}}}}}""", "variables": {"owner": owner, "name": name, "branch": branch}})

    def statuses(self, request):
        statuses = []
        for page in (1, 2):
            batch = self.call(f'/repos/{request["repository"]}/commits/{request["head"]}/statuses?per_page=100&page={page}')
            require(isinstance(batch, list), "status response is malformed")
            statuses.extend(batch)
            if len(batch) < 100:
                return statuses
        raise Refused("admission status census exceeds its bounded read")


def plan(api, event, matrix, targets, now=time.time, pause=time.sleep):
    repository = event.get("repository", {}).get("full_name")
    policy = POLICY.get(repository)
    require(policy and policy["issuer"], "no installed qualified local merge policy")
    require("merge_group" in event, "not a merge candidate")
    run_id = int(os.environ["GITHUB_RUN_ID"])
    run = api.call(f"/repos/{repository}/actions/runs/{run_id}")
    require(run["id"] == run_id and run["run_attempt"] == int(os.environ["GITHUB_RUN_ATTEMPT"]), "run identity differs")
    request = qualified_request(event, run, matrix, targets, policy)
    trusted_chain(request, api.queue(repository, policy["branch"]))
    # Qualification does not authorize a candidate to replace the group commands.
    declarations = [api.call(f'/repos/{repository}/contents/.touchstone.toml?ref={revision}')
                    for revision in (request["base"], request["head"])]
    require(all(item.get("type") == "file" and sha(item.get("sha")) for item in declarations)
            and declarations[0]["sha"] == declarations[1]["sha"], "qualification declaration changed or unavailable")
    pause(ADMISSION_WINDOW)
    # Fetch after the exclusive reservation/JIT acknowledgement, never from vars.
    grant = status_grant(request, api.statuses(request), policy["issuer"], now())
    # A candidate removed or rebuilt during intake cannot retain an assignment.
    trusted_chain(request, api.queue(repository, policy["branch"]))
    return grant


def reserve(state_dir, request, slot, now=time.time):
    """One nonblocking admission under the supervisor's existing register lock.

    The caller nominates an isolated slot; it must recheck capacity/provision
    after this reservation and keep it until the guest is reclaimed. Expiry of
    the status is deliberately not permission to reuse a possibly live slot.
    """
    coordinates(request)
    require(re.fullmatch(r"[A-Za-z0-9._-]+", slot), "invalid slot")
    state_dir = Path(state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    lock = state_dir / "register.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise Refused("supervisor admission is busy") from None
    try:
        require(not (state_dir / "draining").exists(), "supervisor is draining")
        key = hashlib.sha256(context(request).encode()).hexdigest()
        path = state_dir / ("merge-reservation-" + key + ".json")
        if path.exists():
            reservation = json.loads(path.read_text())
            require(reservation["request"] == request and reservation["slot"] == slot, "reservation coordinates differ")
            return {"acquired": False, "reservation": reservation}
        for existing in state_dir.glob("merge-reservation-*.json"):
            require(json.loads(existing.read_text())["slot"] != slot, "isolated slot is reserved")
        reservation = {"v": 1, "request": request, "slot": slot, "reserved_at": now()}
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(reservation) + "\n")
        temporary.replace(path)
        return {"acquired": True, "reservation": reservation}
    finally:
        lock.rmdir()


def publish(api, reservation, receipt, issuer, now=time.time):
    """The controller calls this only after provisioning its reserved guest."""
    request = reservation["request"]
    policy = POLICY.get(request["repository"])
    require(issuer and policy and policy["issuer"] == issuer, "issuer is not installed in committed policy")
    observed = now()
    require(receipt.get("slot") == reservation["slot"] and receipt.get("request") == request, "capacity acknowledgement differs")
    require(reservation["reserved_at"] <= receipt["observed_at"] <= observed
            and observed - receipt["observed_at"] <= 15, "capacity acknowledgement predates reservation or is stale")
    require(receipt.get("isolation") == "kvm" and receipt.get("guest_docker") is True
            and receipt.get("release_slots_preserved") is True and receipt.get("capacity_available") is True
            and receipt.get("registration") == "jit",
            "reserved isolated capacity is not acknowledged")
    runner = api.call(f'/orgs/{request["repository"].split("/")[0]}/actions/runners/{receipt["runner_id"]}')
    labels = {label["name"] for label in runner["labels"]}
    require(runner["id"] == receipt["runner_id"] and runner.get("status") == "online"
            and runner.get("busy") is False,
            "reserved single-use runner is not ready")
    required_labels = {"self-hosted", "linux-kvm-x64-checks", runner_label(request)}
    require(required_labels <= labels <= required_labels | {"Linux", "X64"}, "reserved runner labels differ")
    identity = api.call("/user")
    require(identity.get("id") == issuer["creator_id"] and identity.get("login") == issuer["creator_login"]
            and identity.get("type") == issuer["creator_type"], "controller credential is not the verified service")
    return api.call(f'/repos/{request["repository"]}/statuses/{request["head"]}', {
        "state": "success", "context": context(request), "target_url": run_url(request),
        "description": f'v1;ttl={TTL};capability={request["capability"]};runner={runner["id"]}',
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("plan")
    reservation = subcommands.add_parser("reserve")
    reservation.add_argument("--state-dir", required=True)
    reservation.add_argument("--request", required=True)
    reservation.add_argument("--slot", required=True)
    publication = subcommands.add_parser("publish")
    publication.add_argument("--reservation", required=True)
    publication.add_argument("--receipt", required=True)
    args = parser.parse_args()
    try:
        if args.command == "plan":
            result = plan(GitHub(), json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()),
                          json.loads(os.environ["MATRIX"]), json.loads(os.environ["TARGETS"]))
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f'group={result["group"]}\nlabels={json.dumps(result["labels"], separators=(",", ":"))}\n')
        elif args.command == "reserve":
            print(json.dumps(reserve(args.state_dir, json.loads(Path(args.request).read_text()), args.slot)))
        else:
            reservation = json.loads(Path(args.reservation).read_text())
            receipt = json.loads(Path(args.receipt).read_text())
            issuer = POLICY[reservation["request"]["repository"]]["issuer"]
            print(json.dumps(publish(GitHub(), reservation, receipt, issuer)))
    except (Refused, KeyError, TypeError, ValueError, OSError, urllib.error.URLError) as error:
        print(f"Local merge admission refused: {error}", file=sys.stderr)
        if args.command != "plan":
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
