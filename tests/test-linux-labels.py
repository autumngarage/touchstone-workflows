#!/usr/bin/env python3
"""The labels a local Linux job requires, by event and queue-priority opt-in.

Reads validate-groups' real runs-on expression: its label map is parsed from
the workflow, and the map key's event/opt-in condition is evaluated as written
(GitHub's && and || are value-returning, like Python's and/or).
"""
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
workflow = json.loads(subprocess.check_output([
    "ruby", "-ryaml", "-rjson", "-e", "puts YAML.load_file(ARGV[0]).to_json",
    str(root / ".github/workflows/validate.yml"),
], text=True))
expression = workflow["jobs"]["validate-groups"]["runs-on"]

labels = json.loads(re.search(r"fromJSON\('(\{\"local\".*?\})'\)\[format", expression).group(1))
suffix = re.search(r"matrix\.name\], (github\.event_name .*?)\)\] \}\}$", expression).group(1)
python_suffix = (suffix.replace("github.event_name", "event").replace("vars.LINUX_QUEUE_PRIORITY", "priority")
                 .replace("&&", " and ").replace("||", " or "))
assert re.fullmatch(r"[a-z_ !='\-]+", python_suffix), python_suffix


def runs_on(target, event, priority):
    shared = eval(python_suffix, {}, {"event": event, "priority": priority})  # noqa: S307 - the workflow's own fragment
    return labels[target + shared]


BASE = ["self-hosted", "linux-ephemeral"]
X64 = BASE + ["linux-x64"]
SHARED = ["linux-ephemeral-shared"]

for event in ("merge_group", "pull_request", "push", "workflow_dispatch", "workflow_call"):
    for priority in ("", "false", "true", None):
        shared_required = event != "merge_group" and priority == "true"
        got = (runs_on("local", event, priority), runs_on("local-x64", event, priority))
        want = (BASE + SHARED * shared_required, X64 + SHARED * shared_required)
        assert got == want, f"{event} priority={priority!r}: {got} != {want}"
        # A merge_group job and a job outside the opt-in keep the base labels,
        # which every runner of either role carries.
        assert set(BASE) <= set(got[0]) and set(X64) <= set(got[1])
        # Cloud targets never change with the opt-in.
        assert runs_on("blacksmith", event, priority) == "blacksmith-4vcpu-ubuntu-2404"
        assert runs_on("github", event, priority) == "ubuntu-latest"
print("  OK: local Linux jobs require linux-ephemeral-shared only outside merge_group and only with LINUX_QUEUE_PRIORITY=true")
print("  OK: merge_group jobs keep the base labels, x64 jobs keep linux-x64, cloud targets are unchanged")
