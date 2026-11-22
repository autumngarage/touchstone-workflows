#!/bin/bash
# Starts a job's own Docker daemon, then runs the single-use runner as the
# nonroot `runner` user (LINUX_RUNNER_DOCKER=dind). The runner configuration
# arrives on stdin, never as an argument, for the reason linux-runner.sh gives.
set -euo pipefail
IFS= read -r jit
# Under cgroup v2 a nested daemon needs its own processes out of the root
# group before it can delegate controllers, as Moby's hack/dind does.
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  mkdir -p /sys/fs/cgroup/init
  xargs -rn1 </sys/fs/cgroup/cgroup.procs >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null || :
  sed -e 's/ / +/g' -e 's/^/+/' </sys/fs/cgroup/cgroup.controllers >/sys/fs/cgroup/cgroup.subtree_control
fi
dockerd --host=unix:///var/run/docker.sock --group=docker >/tmp/dockerd.log 2>&1 &
as_runner() { setpriv --reuid=runner --regid=runner --init-groups "$@"; }
for _ in $(seq 1 60); do
  as_runner docker info >/dev/null 2>&1 && break
  sleep 1
done
if ! as_runner docker info >/dev/null 2>&1; then
  echo "job-entry: the job's Docker daemon did not answer the runner user" >&2
  tail -n 40 /tmp/dockerd.log >&2
  exit 1
fi
cd /home/runner
exec setpriv --reuid=runner --regid=runner --init-groups ./run.sh --jitconfig "$jit"
