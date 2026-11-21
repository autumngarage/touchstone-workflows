#!/usr/bin/env python3
"""Existing Runscaler event adapter and fixed disposable KVM slot.

Runscaler logs are wake-up hints, never authorization. All assignments are
re-read from GitHub and pass the protected merge routing contract.
"""
import argparse
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import time
import urllib.error

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("routing", HERE / "merge-routing.py")
routing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routing)
require = routing.require
SOURCE_SIGNAL_NAME = "Local merge admission signal"
SIGNAL_NAME = "intake / " + SOURCE_SIGNAL_NAME
UNIT = "hesperus-kvm-guest.service"
CONTROL_IMAGE = "127.0.0.1:5000/hesperus/runner@sha256:7d669156418c995e9ddd99d2f5bba88b1385e35b497fad00419197921ef9450d"
INSTALL_FILES = {
    "kvm-admission.py": ("/opt/hesperus-runner/kvm-admission.py", "0555"),
    "merge-routing.py": ("/opt/hesperus-runner/merge-routing.py", "0444"),
    "jit.sh": ("/opt/hesperus-runner/jit.sh", "0444"),
    "kvm-guest.sh": ("/opt/hesperus-runner/kvm-guest.sh", "0555"),
    "runscaler-intake.sh": ("/opt/hesperus-runner/runscaler-intake.sh", "0555"),
    "hesperus-kvm-guest.service": ("/etc/systemd/system/hesperus-kvm-guest.service", "0444"),
    "hesperus-kvm-guard.service": ("/etc/systemd/system/hesperus-kvm-guard.service", "0444"),
    "hesperus-runscaler-intake.conf": ("/etc/systemd/system/hesperus-runscaler.service.d/40-native-intake.conf", "0444"),
    "hesperus-kvm.sudoers": ("/etc/sudoers.d/hesperus-kvm", "0440"),
    "runscaler-intake.toml": ("/etc/hesperus-runscaler/runscaler.toml", "0444"),
}


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=10, **kwargs).strip()


def capacity(run=command, memory=None, cgroup=None):
    # Containers can terminate between ps and inspect. One fresh local snapshot
    # resolves that race; unavailable evidence still closes the guest guard.
    for attempt in range(2):
        try:
            return capacity_snapshot(run, memory, cgroup)
        except (routing.Refused, FileNotFoundError, subprocess.SubprocessError):
            if attempt:
                raise
            time.sleep(0.1)


def capacity_snapshot(run=command, memory=None, cgroup=None):
    """The measured release guard, also refusing another KVM slot owner."""
    memory = Path("/proc/meminfo").read_text() if memory is None else memory
    available = re.search(r"^MemAvailable:\s+(\d+) kB$", memory, re.M)
    require(available and int(available[1]) > 4 * 1024 * 1024, "host headroom is unavailable")
    rows = run(["ps", "-e", "-o", "pid=,comm="]).splitlines()
    main_pid = run(["systemctl", "show", UNIT, "--property=MainPID", "--value"])
    containers = run(["docker", "ps", "--format", "{{.Names}}"]).splitlines()
    slots = [re.fullmatch(r"linux-ephemeral-ci-linux-01-([1-4])-\d+", name) for name in containers]
    require(sorted(match[1] for match in slots if match) == list("1234"), "reserved release inventory differs")
    cpu = ram = 0
    roles = {}
    for name, match in zip(containers, slots):
        container = json.loads(run(["docker", "inspect", name]))[0]
        if match:
            roles[container["Id"]] = "release"
            continue
        info = container["HostConfig"]
        if re.fullmatch(r"runner-[0-9a-f]{8}", name):
            require(container["Config"]["Labels"].get("managed-by") == "runner"
                    and container["Config"]["Image"] == CONTROL_IMAGE and info.get("Privileged") is False
                    and container.get("Mounts") == [] and info.get("NetworkMode") == "hesperus-runscaler-pilot",
                    "control container isolation differs")
            roles[container["Id"]] = "control"
        nano, quota, period, limit = [info[key] for key in ("NanoCpus", "CpuQuota", "CpuPeriod", "Memory")]
        require(all(type(value) is int and value >= 0 for value in (nano, quota, period, limit)), "unknown sibling limits")
        if quota and period:
            measured = (quota * 1_000_000_000 + period - 1) // period
            require(not nano or nano * period == quota * 1_000_000_000, "inconsistent sibling CPU limit")
        else:
            require(nano and quota == period == 0, "unbounded sibling CPU")
            measured = nano
        require(limit > 0, "unbounded sibling memory")
        cpu += measured
        ram += limit
    require(cpu <= 2_000_000_000 and ram <= 4 * 1024**3, "sibling work owns headroom")
    listeners = {}
    for row in rows:
        pid, name = row.split(maxsplit=1)
        require(not name.startswith("qemu-system") or pid == main_pid, "another guest owns capacity")
        if name not in ("Runner.Listener", "Runner.Worker"):
            continue
        membership = cgroup(pid) if cgroup else Path(f"/proc/{pid}/cgroup").read_text()
        owners = [identity for identity in roles if identity in membership]
        require(len(owners) == 1, "unattributed runner process owns capacity")
        owner = owners[0]
        require(name != "Runner.Worker" or roles[owner] == "control", "release work owns capacity")
        if name == "Runner.Listener":
            listeners[owner] = listeners.get(owner, 0) + 1
    require(all(listeners.get(identity) == 1 for identity, role in roles.items() if role == "release"), "four reserved release listeners are not intact")
    require(sum(role == "control" for role in roles.values()) <= 1, "multiple control workers own capacity")
    return {"available_kib": int(available[1]), "release_slots_preserved": True, "observed_at": time.time()}


def signal_hint(line):
    event = json.loads(line)
    require(isinstance(event, dict), "control event is not an object")
    if event.get("prefix") != "hesperus-runscaler-pc":
        return None
    if (event.get("msg"), event.get("reason"), event.get("result"), event.get("job")) != (
            "Runner removed", "job-completed", "succeeded", SIGNAL_NAME):
        return None
    require(type(event.get("workflowRunId")) is int and event["workflowRunId"] > 0, "invalid hint run")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", event.get("repo", "")), "invalid hint repository")
    return event["repo"], event["workflowRunId"]


def control_lines(stream, buffered):
    chunk = os.read(stream.fileno(), 65536)
    if not chunk:
        return [], b"", True
    buffered += chunk
    require(len(buffered) <= 1024 * 1024, "control log line exceeds bound")
    *lines, buffered = buffered.split(b"\n")
    return [line.decode("utf-8", errors="replace") for line in lines], buffered, False


def authoritative_request(api, registration_api, hint, config):
    repository, signal_id = hint
    policy = routing.POLICY.get(repository)
    require(policy and policy["issuer"], "verified App is not installed")
    require(config["signal_source_sha"] and routing.sha(config["signal_source_sha"]), "signal source is not pinned")
    signal = api.call(f"/repos/{repository}/actions/runs/{signal_id}")
    require(signal.get("id") == signal_id and signal.get("repository", {}).get("id") == policy["repository_id"]
            and signal.get("event") == "merge_group" and signal.get("workflow_id") == config["signal_workflow_id"]
            and signal.get("path") == ".github/workflows/local-merge-intake.yml"
            and signal.get("status") in ("in_progress", "completed") and signal.get("conclusion") in (None, "success"), "signal run is not qualified")
    source = f'autumngarage/touchstone-workflows/.github/workflows/merge-intake.yml@{config["signal_source_sha"]}'
    references = signal.get("referenced_workflows")
    require(isinstance(references, list) and len(references) == 1 and references[0].get("path") == source
            and references[0].get("sha") == config["signal_source_sha"], "signal source/ref differs")
    jobs = api.call(f'/repos/{repository}/actions/runs/{signal_id}/attempts/{signal["run_attempt"]}/jobs?per_page=100')
    require(jobs.get("total_count") == 1 and len(jobs["jobs"]) == 1, "signal job census differs")
    job = jobs["jobs"][0]
    require(job.get("name") == SIGNAL_NAME and job.get("head_sha") == signal["head_sha"]
            and job.get("run_id") == signal_id and job.get("run_attempt") == signal["run_attempt"]
            and job.get("status") == "completed" and job.get("conclusion") == "success"
            and job.get("runner_group_id") == config["control_group_id"]
            and job.get("runner_id") and job.get("labels") == [config["control_label"]], "control job or registration differs")
    control_group = registration_api.call(f'/orgs/{repository.split("/")[0]}/actions/runner-groups/{config["control_group_id"]}')
    require(control_group.get("visibility") == "selected" and control_group.get("allows_public_repositories") is False
            and control_group.get("restricted_to_workflows") is True and control_group.get("selected_workflows") == [source], "control group trust differs")
    # The optional signal cannot become an accidental required-workflow wait.
    rules = api.call(f"/repos/{repository}/rules/branches/{policy['branch']}")
    for rule in rules:
        parameters = rule.get("parameters", {})
        for workflow in parameters.get("workflows", []):
            require(workflow.get("path") not in (".github/workflows/merge-intake.yml", ".github/workflows/local-merge-intake.yml"), "signal is a required workflow")
        require(all(check["context"] not in (SOURCE_SIGNAL_NAME, SIGNAL_NAME) for check in parameters.get("required_status_checks", [])), "signal is a required status")
    runs = api.call(f'/repos/{repository}/actions/runs?event=merge_group&head_sha={signal["head_sha"]}&per_page=100')
    require(runs.get("total_count", 101) <= 100, "native run census exceeds bound")
    matches = [run for run in runs["workflow_runs"] if run.get("workflow_id") == policy["workflow_id"] and run.get("status") in ("queued", "in_progress")]
    require(len(matches) == 1, "no unique current native validation")
    run = api.call(f'/repos/{repository}/actions/runs/{matches[0]["id"]}')
    branch = re.fullmatch(rf'gh-readonly-queue/{re.escape(policy["branch"])}/pr-[1-9][0-9]*-([0-9a-f]{{40}})', run.get("head_branch", ""))
    require(branch, "native candidate ref is not authoritative")
    event = {"repository": signal["repository"], "merge_group": {"base_ref": "refs/heads/" + policy["branch"],
             "base_sha": branch[1], "head_sha": signal["head_sha"], "head_ref": "refs/heads/" + run["head_branch"]}}
    request = routing.qualified_request(event, run, {"include": [{"name": policy["group"], "group": policy["group"]}]}, {policy["group"]: "github"}, policy)
    routing.trusted_chain(request, api.queue(repository, policy["branch"]))
    native_jobs = api.call(f'/repos/{repository}/actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs?per_page=100')
    require(native_jobs.get("total_count", 101) <= 100, "native jobs exceed census bound")
    require(not any(job.get("name") == f'validate-groups ({policy["group"]}, {policy["group"]})' for job in native_jobs["jobs"]), "planner already assigned the group")
    group = registration_api.call(f'/orgs/{repository.split("/")[0]}/actions/runner-groups/{config["routine_group_id"]}')
    require(group.get("visibility") == "selected" and group.get("allows_public_repositories") is False
            and group.get("restricted_to_workflows") is True and group.get("selected_workflows") == [config["validation_source_ref"]], "routine group trust differs")
    return request


def guest_ssh(config, remote):
    # SSH reaches only AF_VSOCK; no listening port or host network is exposed.
    return ["ssh", "-F", "/dev/null", "-i", config["guest_key"], "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=yes", "-o", "ProxyUseFdpass=yes",
            "-o", "HostKeyAlias=hesperus-kvm-routine", "-o", "UserKnownHostsFile=" + config["guest_known_hosts"],
            "-o", "ProxyCommand=python3 -I /opt/hesperus-runner/kvm-admission.py vsock",
            "pilot@hesperus-kvm-routine", remote]


def admit(api, registration_api, config, request):
    capacity()
    require(command(["systemctl", "is-active", UNIT]) == "active", "guest is not ready")
    image = config["runner_image"]
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", image), "runner image is not immutable")
    require(command(guest_ssh(config, f"docker image inspect --format '{{{{.Id}}}}' {image}")) == image, "guest runner image is not ready")
    result = routing.reserve(config["state_dir"], request, "pc-kvm")
    require(result["acquired"], "request already owns a reservation")
    reservation = result["reservation"]
    # Reuse the registration owner. No credential is passed in argv or guest env.
    response = command(["bash", "-c", '. "$1"; request_jit "$2" "$3" "$4"', "bash", str(HERE / "jit.sh"),
                        routing.runner_label(request), str(config["routine_group_id"]), routing.runner_label(request)],
                       env=dict(os.environ, ORG=request["repository"].split("/")[0], LABEL="linux-kvm-x64-checks"))
    jit = json.loads(response)
    require(jit.get("encoded_jit_config") and jit.get("runner", {}).get("id"), "JIT registration was not acknowledged")
    reservation["runner_id"] = jit["runner"]["id"]
    reservation["registration_at"] = time.time()
    reservation_file(config, reservation).write_text(json.dumps(reservation) + "\n")
    remote = (f"docker run --rm -i --cpus 2 --memory 3g --pids-limit 4096 "
              f"--group-add $(stat -c %g /var/run/docker.sock) -v /var/run/docker.sock:/var/run/docker.sock "
              f"{image} bash -c 'IFS= read -r jit && exec ./run.sh --jitconfig \"$jit\"'")
    worker = subprocess.Popen(guest_ssh(config, remote), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
    worker.stdin.write((jit["encoded_jit_config"] + "\n").encode())
    worker.stdin.close()
    # Runner registration acknowledgement has its own small, bounded deadline.
    deadline = time.monotonic() + 8
    while True:
        runner = registration_api.call(f'/orgs/{request["repository"].split("/")[0]}/actions/runners/{jit["runner"]["id"]}')
        if runner.get("status") == "online":
            break
        require(worker.poll() is None and time.monotonic() < deadline, "JIT runner did not become ready")
        time.sleep(1)
    observed = capacity()
    receipt = {"request": request, "slot": "pc-kvm", "observed_at": observed["observed_at"], "isolation": "kvm",
               "architecture": "x64", "guest_docker": True, "release_slots_preserved": True,
               "capacity_available": True, "registration": "jit", "runner_id": runner["id"]}
    routing.publish(api, registration_api, config["state_dir"], reservation, receipt, routing.POLICY[request["repository"]]["issuer"])
    return worker, reservation, runner["id"]


def reservation_file(config, reservation):
    key = hashlib.sha256(routing.context(reservation["request"]).encode()).hexdigest()
    return Path(config["state_dir"]) / ("merge-reservation-" + key + ".json")


def reconcile(api, registration_api, config, reservation, worker=None):
    """Never replace a guest until its exact native assignment is terminal."""
    request = reservation["request"]
    response = api.call(f'/repos/{request["repository"]}/actions/runs/{request["run_id"]}/attempts/{request["attempt"]}/jobs?per_page=100')
    require(response.get("total_count", 101) <= 100, "native reconciliation census exceeds bound")
    matches = [job for job in response["jobs"] if job.get("name") == f'validate-groups ({request["group"]}, {request["group"]})']
    require(len(matches) <= 1, "ambiguous native reconciliation")
    run = api.call(f'/repos/{request["repository"]}/actions/runs/{request["run_id"]}')
    terminal = (matches and matches[0].get("status") == "completed") or run.get("status") == "completed"
    expected_labels = {"self-hosted", "linux-kvm-x64-checks", routing.runner_label(request)}
    assigned_elsewhere = bool(matches and matches[0].get("labels") and set(matches[0]["labels"]) != expected_labels)
    if not terminal and not assigned_elsewhere:
        return False
    runner_id = reservation.get("runner_id")
    if not runner_id:
        # Registration can succeed just before a disk/process failure. Recover
        # by its exact unique label/name, never by fleet prefix or slot age.
        listing = registration_api.call(f'/orgs/{request["repository"].split("/")[0]}/actions/runners?per_page=100')
        require(listing.get("total_count", 101) <= 100, "registration recovery exceeds census bound")
        candidates = [runner for runner in listing["runners"] if runner.get("name") == routing.runner_label(request)
                      and any(label.get("name") == routing.runner_label(request) for label in runner.get("labels", []))]
        require(len(candidates) <= 1, "registration ownership is ambiguous")
        runner_id = candidates[0]["id"] if candidates else None
    if runner_id:
        try:
            registration_api.call(f'/orgs/{request["repository"].split("/")[0]}/actions/runners/{runner_id}', method="DELETE")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
    # systemd waits for this fixed guest's process group to terminate. It does
    # not affect the independent release supervisor or another guest's unit.
    subprocess.run(["sudo", "-n", "systemctl", "stop", UNIT], check=True, timeout=40)
    require(command(["systemctl", "show", UNIT, "--property=MainPID", "--value"]) == "0", "guest is not reclaimed")
    if worker:
        worker.wait(timeout=10)
    path = reservation_file(config, reservation)
    require(json.loads(path.read_text()) == reservation, "reservation ownership changed")
    path.unlink()
    return True


class StatusAPI(routing.GitHub):
    """Read the operator-rotated short-lived installation token per request."""
    def __init__(self, path):
        self.path = Path(path)
        super().__init__(self.read_token())

    def read_token(self):
        info = self.path.lstat()
        require(self.path.is_file() and not self.path.is_symlink()
                and info.st_mode & 0o777 in (0o400, 0o600)
                and info.st_uid in (0, os.geteuid()), "status credential is not private")
        token = self.path.read_text().strip()
        require(bool(token), "status credential is unavailable")
        return token

    def call(self, path, payload=None, method=None):
        self.token = self.read_token()
        return super().call(path, payload, method)


def prepare(config):
    """Prewarm only the one isolated slot, outside the billable planner path."""
    require(routing.POLICY[config["repository"]]["issuer"], "verified App is not installed; activation refused")
    require(not list(Path(config["state_dir"]).glob("merge-reservation-*.json")), "owned reservation must be reconciled before guest replacement")
    capacity()
    subprocess.run(["sudo", "-n", "systemctl", "start", UNIT], check=True, timeout=20)
    deadline = time.monotonic() + 120
    while True:
        try:
            command(guest_ssh(config, "docker info --format '{{.ServerVersion}}'"), stderr=subprocess.DEVNULL)
            break
        except subprocess.SubprocessError:
            require(time.monotonic() < deadline, "guest did not become ready")
            time.sleep(2)
    image = config["runner_image"]
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", image), "runner image is not immutable")
    try:
        command(guest_ssh(config, f"docker image inspect --format '{{{{.Id}}}}' {image}"), stderr=subprocess.DEVNULL)
    except subprocess.SubprocessError:
        # This is a trusted dependency image, not a candidate checkout. The
        # guest receives image bytes only; registration/App credentials stay out.
        require(command(["docker", "image", "inspect", "--format", "{{.Id}}", image]) == image, "host image differs")
        export = subprocess.Popen(["docker", "save", image], stdout=subprocess.PIPE)
        try:
            subprocess.run(guest_ssh(config, "docker load"), stdin=export.stdout, check=True, timeout=120)
            export.stdout.close()
            require(export.wait(timeout=10) == 0, "image export failed")
        finally:
            if export.poll() is None:
                export.terminate()
                export.wait(timeout=10)


def installation_plan(config):
    files = [{"source": source, "target": target, "mode": mode} for source, (target, mode) in INSTALL_FILES.items()]
    require(all((HERE / item["source"]).is_file() for item in files), "installation source is incomplete")
    return {"changes": False, "files": files, "units": [UNIT, "hesperus-kvm-guard.service"],
            "required_files": ["base.qcow2", "seed.iso", "guest-key", "guest-known-hosts"],
            "installed_issuer": bool(routing.POLICY[config["repository"]]["issuer"]),
            "qualified_target": bool(config.get("signal_source_sha") and config.get("signal_workflow_id") and config.get("routine_group_id")),
            "release_service_changed": False}


def activation_check(config):
    issuer = routing.POLICY[config["repository"]]["issuer"]
    require(issuer and issuer.get("creator_type") == "Bot" and routing.integer(issuer.get("app_id"))
            and routing.integer(issuer.get("creator_id")), "verified App is not installed; activation refused")
    require(routing.sha(config.get("signal_source_sha")) and routing.integer(config.get("signal_workflow_id"))
            and routing.integer(config.get("routine_group_id"))
            and re.fullmatch(r"autumngarage/touchstone-workflows/\.github/workflows/validate.yml@[0-9a-f]{40}", config.get("validation_source_ref") or ""),
            "native target has not been qualified")
    StatusAPI(config["status_token_file"])
    for filename, key in (("base.qcow2", "base_sha256"), ("seed.iso", "seed_sha256")):
        expected = config.get(key)
        require(isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected), "guest input has not been qualified")
        path = Path("/etc/hesperus-kvm") / filename
        info = path.lstat()
        require(not path.is_symlink() and path.is_file() and info.st_uid == 0 and info.st_mode & 0o222 == 0, "guest input is mutable")
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        require(digest.hexdigest() == expected, "guest input differs from qualification")
    key = Path(config["guest_key"])
    require(key.is_file() and not key.is_symlink() and key.stat().st_mode & 0o777 in (0o400, 0o600), "guest control key is not private")
    require(Path(config["guest_known_hosts"]).is_file(), "guest identity has not been pinned")


def guard():
    destination = os.environ.get("NOTIFY_SOCKET")
    require(destination, "guard must run under its systemd notify service")
    initial = True
    while True:
        capacity()
        if initial:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
                channel.connect(destination.replace("@", "\0", 1) if destination.startswith("@") else destination)
                channel.send(b"READY=1")
            initial = False
        time.sleep(3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("guard", "vsock", "install-dry-run", "activation-check", "prepare", "listen"))
    parser.add_argument("--config", default="/etc/hesperus-kvm/admission.json")
    args = parser.parse_args()
    if args.command == "vsock":
        import array
        with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as channel:
            channel.settimeout(3)
            channel.connect((14695, 22))
            channel.setblocking(True)
            with socket.socket(fileno=1) as proxy:
                proxy.sendmsg([b"1"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [channel.fileno()]))])
        return
    if args.command == "guard":
        guard()
        return
    config = json.loads(Path(args.config).read_text())
    if args.command == "install-dry-run":
        print(json.dumps(installation_plan(config), indent=2))
        return
    activation_check(config)
    if args.command == "activation-check":
        return
    if args.command == "prepare":
        prepare(config)
        return
    api, registration_api = StatusAPI(config["status_token_file"]), routing.GitHub()
    retained = list(Path(config["state_dir"]).glob("merge-reservation-*.json"))
    require(len(retained) <= 1, "multiple slot reservations need reconciliation")
    active = (None, json.loads(retained[0].read_text()), None) if retained else None
    manager = subprocess.Popen(["/opt/runscaler/v0.23.0/runner", "run", "--log-format", "json", "--config",
                                "/etc/hesperus-runscaler/runscaler.toml"], stdout=subprocess.PIPE, bufsize=0)
    stopping = False
    manager_stopped = False
    def stop(_number, _frame):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    next_reconciliation = 0
    next_prepare = 0
    buffered = b""
    while True:
        if stopping and not manager_stopped:
            manager.terminate()
            manager_stopped = True
        if active and time.monotonic() >= next_reconciliation:
            next_reconciliation = time.monotonic() + 120
            try:
                if reconcile(api, registration_api, config, active[1], active[0]):
                    active = None
                    next_prepare = 0
            except (routing.Refused, OSError, subprocess.SubprocessError) as error:
                print(f"Local reservation retained: {error}", file=sys.stderr)
        if not active and not stopping and time.monotonic() >= next_prepare:
            next_prepare = time.monotonic() + 120
            try:
                prepare(config)
            except (routing.Refused, OSError, subprocess.SubprocessError) as error:
                print(f"Local guest unavailable: {error}", file=sys.stderr)
        if stopping and not active:
            subprocess.run(["sudo", "-n", "systemctl", "stop", UNIT], check=True, timeout=40)
            raise SystemExit(manager.wait(timeout=310))
        stream = manager.stdout if manager.poll() is None else None
        if stream is None:
            stopping = True
            manager_stopped = True
            time.sleep(1)
            continue
        ready, _, _ = select.select([stream], [], [], 1)
        if not ready:
            continue
        lines, buffered, eof = control_lines(stream, buffered)
        if eof:
            stopping = True
            continue
        for line in lines:
            print(line, flush=True)
            try:
                hint = signal_hint(line)
                if hint and not active and not stopping:
                    request = authoritative_request(api, registration_api, hint, config)
                    active = admit(api, registration_api, config, request)
            except (routing.Refused, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
                print(f"Local admission unavailable: {error}", file=sys.stderr)
                # A lost response never releases capacity. Restart resumes the lease.
                retained = list(Path(config["state_dir"]).glob("merge-reservation-*.json"))
                if retained:
                    require(len(retained) == 1, "multiple slot reservations need reconciliation")
                    active = (None, json.loads(retained[0].read_text()), None)


if __name__ == "__main__":
    try:
        main()
    except (routing.Refused, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Local admission unavailable: {error}", file=sys.stderr)
        sys.exit(1)
