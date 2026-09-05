#!/usr/bin/env bash
# Every `run:` block is its own shell. A variable assigned in one and read in a
# later one is unbound there, and under `set -u` the step dies before doing any
# work — which is how 46efeaa broke delivery-evidence for every pinned
# repository (`touchstone_revision: unbound variable`). The static assertions in
# test-workflow.sh cannot see it: the name is present and spelled correctly in
# both blocks, and only the scope between them is wrong.
#
# Scope of this check, deliberately narrow so it cannot cry wolf: a name is
# suspect only if some `run:` block in the same job assigns it as a shell
# variable. A later block that reads that name without assigning it, and without
# an earlier step publishing it to $GITHUB_ENV, is the bug. Names never assigned
# as shell variables are out of scope — they are runner or env values, or `$var`
# references inside embedded jq programs, and neither is a cross-step defect.
set -euo pipefail

repo_root="${TOUCHSTONE_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export TOUCHSTONE_CONTRACT_ROOT="$repo_root"

python3 - "$@" <<'PY'
import glob
import os
import re
import sys

repo_root = os.environ["TOUCHSTONE_CONTRACT_ROOT"]
targets = sys.argv[1:] or sorted(glob.glob(os.path.join(repo_root, ".github/workflows/*.yml")))

IDENT = r"[a-z][a-z0-9_]*"
ASSIGN = re.compile(r"^[ \t]*(?:export[ \t]+)?(" + IDENT + r")=", re.M)
ASSIGN_INLINE = re.compile(r"(?:[;&|]|\bthen|\bdo|\belse)[ \t]+(" + IDENT + r")=")
FOR_IN = re.compile(r"\bfor[ \t]+(" + IDENT + r")[ \t]+in\b")
READ_IN = re.compile(r"\bread[ \t]+(?:-[A-Za-z]+[ \t]+)*(" + IDENT + r"(?:[ \t]+" + IDENT + r")*)")
REF = re.compile(r"\$\{(" + IDENT + r")[}:]|\$(" + IDENT + r")\b")
TO_ENV = re.compile(
    r"(?:printf|echo)\b[^\n]*?\b([A-Za-z_][A-Za-z0-9_]*)=[^\n]*>>[ \t]*\"?\$\{?GITHUB_ENV\}?\"?"
)


def run_blocks(path):
    """(job, step, line_no, script) for every run: block, in file order."""
    lines = open(path, encoding="utf-8").read().splitlines()
    job, step, out, i = None, 0, [], 0
    while i < len(lines):
        line = lines[i]
        jm = re.match(r"^  ([A-Za-z0-9_-]+):[ \t]*$", line)
        if jm:
            job, step = jm.group(1), 0
        if re.match(r"^[ \t]*- (?:name|uses|run):", line):
            step += 1
        rm = re.match(r"^([ \t]*)run:[ \t]*\|", line)
        if rm:
            base = len(rm.group(1))
            body, j = [], i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= base:
                    break
                body.append(nxt)
                j += 1
            out.append((job, step, i + 1, "\n".join(body)))
            i = j
            continue
        i += 1
    return out


def assigned_in(script):
    names = set(ASSIGN.findall(script))
    names |= set(ASSIGN_INLINE.findall(script))
    names |= set(FOR_IN.findall(script))
    for group in READ_IN.findall(script):
        names |= set(group.split())
    return names


def referenced_in(script):
    return {a or b for a, b in REF.findall(script)}


failures = []
for path in targets:
    rel = os.path.relpath(path, repo_root)
    blocks = run_blocks(path)
    by_job = {}
    for job, step, line_no, script in blocks:
        by_job.setdefault(job, []).append((step, line_no, script))
    for job, items in by_job.items():
        shell_vars = set()
        for _, _, script in items:
            shell_vars |= assigned_in(script)
        published = set()
        for step, line_no, script in items:
            local = assigned_in(script)
            for name in sorted(referenced_in(script) & shell_vars):
                if name in local or name in published:
                    continue
                failures.append(
                    "%s:%d job '%s' step %d reads $%s, which another run: block "
                    "assigns but this one does not. Each run: block is a separate "
                    "shell, so under set -u this dies as an unbound variable. "
                    "Publish it with: printf '%s=%%s\\n' \"$%s\" >>\"$GITHUB_ENV\""
                    % (rel, line_no, job, step, name, name.upper(), name)
                )
            published |= {n.lower() for n in TO_ENV.findall(script)}
            published |= set(TO_ENV.findall(script))

if failures:
    for f in failures:
        print("FAIL: " + f, file=sys.stderr)
    print("==> FAIL: %d cross-step shell scope error(s)" % len(failures), file=sys.stderr)
    sys.exit(1)

print("==> PASS: no run: block reads a shell variable another block owns")
PY
