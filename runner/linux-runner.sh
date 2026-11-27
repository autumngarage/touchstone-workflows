#!/usr/bin/env bash
#
# runner/linux-runner.sh -- keep single-use self-hosted Linux runners for the
# validate workflow: one throwaway container per job (AUT-1596).
#
# Usage:
#   bash runner/linux-runner.sh build       build the job image from runner/Dockerfile
#   bash runner/linux-runner.sh run         supervise the runner slots in the foreground
#   sudo bash runner/linux-runner.sh install-daemon USER
#                                           run them at boot as USER from a
#                                           LaunchDaemon, with no login session
#   sudo bash runner/linux-runner.sh stop-daemon
#                                           stop the LaunchDaemon once its jobs finish
#   sudo bash runner/linux-runner.sh uninstall-daemon
#                                           stop and remove the LaunchDaemon
#   bash runner/linux-runner.sh status      show the daemon, containers, and registrations
#
# The model is deliberately simple: N slots, one job each. Every runner
# registers with self-hosted, linux-ephemeral and its engine's architecture
# (linux-x64 or linux-arm64), so a group that needs an x86-64 engine can ask
# for one. Routing is static: validate.yml selects
# ["self-hosted","linux-ephemeral"] when a repository's LINUX_PR_RUNNER or
# LINUX_QUEUE_RUNNER variable says `local` (see "Runner" in README.md). There
# is no watcher, no overflow, and no cache image.
#
# The one policy beyond that is runner/queue.sh's, shared with the Mac pool
# (AUT-2813): each runner's role is chosen when it registers, from what waits
# (see LINUX_RUNNER_QUEUE_SLOTS below). A shared runner also carries
# linux-ephemeral-shared; a queue-only one carries the base labels alone.
#
# Each slot asks GitHub for a just-in-time runner configuration, which
# registers a runner for exactly one job, starts a fresh container from the
# job image with that configuration, and waits for it to exit. The container
# receives the single-use configuration and nothing else: no volume, no Docker
# socket, no host network, no credential. Nothing a job does reaches another
# job, which is what lets `validate` -- it runs the candidate's declared
# commands -- use these runners at all.
#
# Configuration, from the environment (defaults in parentheses):
#   LINUX_RUNNER_ORG      organization (autumngarage)
#   LINUX_RUNNER_GROUP    runner group, restricted to the private consumers (linux-ephemeral)
#   LINUX_RUNNER_NAME     the name this supervisor's runners and containers
#                         start with, after linux-ephemeral- (the short host
#                         name). A second supervisor on one host needs its own:
#                         a named supervisor keeps its own state directory, and
#                         each one removes only the leftover containers and
#                         offline registrations whose whole name is its own
#   LINUX_RUNNER_SLOTS    jobs run at once (2)
#   LINUX_RUNNER_MEMORY   memory limit per job container (6g)
#   LINUX_RUNNER_CPUS     CPU limit per job container (4)
#   LINUX_RUNNER_PIDS     process limit per job container (4096): a pull
#                         request that forks without end exhausts its own
#                         container, not the VM every slot shares
#   LINUX_RUNNER_IMAGE    job image tag (linux-ephemeral-runner:local)
#   LINUX_RUNNER_DOCKER   none (default) or dind: each job starts its own Docker
#                         daemon, for validation groups that run containers.
#                         The job container runs under Sysbox, not --privileged:
#                         its daemon and anything it starts, privileged or not,
#                         stay inside the job's user namespace and cannot reach
#                         the VM or the other slots. The engine must offer the
#                         sysbox-runc runtime; on Colima this script installs a
#                         pinned Sysbox and owns the VM's configuration.
#   LINUX_RUNNER_ENGINE   docker: use the Docker engine already running (Docker
#                         Desktop in a login session); colima: start this
#                         user's Colima VM first, which needs no login session
#                         (docker)
#   LINUX_RUNNER_VM_CPUS  CPUs for the Colima VM (8)
#   LINUX_RUNNER_VM_MEMORY  GiB for the Colima VM (16)
#   LINUX_RUNNER_VM_DISK  GiB of disk for the Colima VM (60). Colima sizes the
#                         disk when it creates the VM: an existing VM keeps
#                         its disk size until it is deleted and created again
#   LINUX_RUNNER_TOKEN_FILE  a file holding the GitHub token gh uses, read when
#                         GH_TOKEN is unset; it must be readable by its owner
#                         only. A daemon has no login keychain, so this is its
#                         credential (unset: gh's own login)
#   LINUX_RUNNER_LOG_FILE  the file run appends its output to, reopened for
#                         every line so newsyslog can rotate it (unset:
#                         stdout). install-daemon sets it
#
#   LINUX_RUNNER_QUEUE_SLOTS  queue priority (0: every runner is shared). GitHub
#                         hands a freed runner to whichever job asks first, not
#                         the one that waited longest, so a burst of pull-request
#                         jobs can starve merge-queue jobs past the queue's
#                         check timeout. Above 0, each runner's role is chosen
#                         when it registers, from the jobs waiting for this
#                         label (runner/queue.sh): queue-only when queue jobs
#                         wait beyond the idle queue-only runners, else one of
#                         the first QUEUE_SLOTS slots while no pull-request job
#                         waits, else shared. At most SLOTS-1 runners are
#                         queue-only. A merge-queue job selects the base labels
#                         and takes either role; every other job selects
#                         linux-ephemeral-shared (validate.yml, opt-in with
#                         LINUX_QUEUE_PRIORITY). Must be fewer than SLOTS. It
#                         needs Actions read access to every repository of the
#                         group; without it the first QUEUE_SLOTS slots are
#                         queue-only, fixed. Demand needs no API call at 0.
#   LINUX_RUNNER_JANITOR_INTERVAL  seconds between looks for idle queue-only
#                         runners no queue job needs (120)
#
# Retired, still accepted because an installed wrapper may pass it:
#   LINUX_RUNNER_CACHE_SEED   the job-image Swift cache. Ignored, with a note in
#                         the log; every job starts from the base image
#
# The host needs docker and a gh login with admin:org, or a token that can
# manage the organization's self-hosted runners (a fine-grained token with the
# organization permission "Self-hosted runners: read and write" is enough).
# The token is used here to register runners and never enters a container.
#
# install-daemon is for a headless Mac that runs other CI too: the fleet runs
# as its own account, so the token that registers runners is readable by no
# job that runs on the Mac (a macOS runner's jobs run as another user).
#
# Runs under macOS's /bin/bash 3.2: no associative arrays, mapfile, or wait -n.

set -euo pipefail

ORG="${LINUX_RUNNER_ORG:-autumngarage}"
GROUP="${LINUX_RUNNER_GROUP:-linux-ephemeral}"
# The one label validate.yml selects, literally; jit.sh registers it.
LABEL=linux-ephemeral
SLOTS="${LINUX_RUNNER_SLOTS:-2}"
QUEUE_SLOTS="${LINUX_RUNNER_QUEUE_SLOTS:-0}"
# Every GitHub read counts against the quota every agent on this Mac shares.
JANITOR_INTERVAL="${LINUX_RUNNER_JANITOR_INTERVAL:-120}"
# The lock merge-routing.py also takes: one registration or admission at a time.
REGISTER_LOCK=register.lock
MEMORY="${LINUX_RUNNER_MEMORY:-6g}"
CPUS="${LINUX_RUNNER_CPUS:-4}"
PIDS="${LINUX_RUNNER_PIDS:-4096}"
IMAGE="${LINUX_RUNNER_IMAGE:-linux-ephemeral-runner:local}"
JOB_DOCKER="${LINUX_RUNNER_DOCKER:-none}"
# The Sysbox release a dind Colima VM installs, and its arm64 package digest
# from https://github.com/nestybox/sysbox/releases/tag/v0.7.1.
SYSBOX_VERSION=0.7.1
SYSBOX_SHA256=04ca894ae0b53f0fa54eaacc173ce40363c9a95ea5450f773716a84ef650a69b
# On the VM data disk Colima mounts at /var/lib/docker; see sysbox_install_script.
SYSBOX_DATA_ROOT=/var/lib/docker/sysbox
# A job's writable layers peak near 18 GiB (three full hesperus jobs held 55 GiB,
# 2026-11-27). Below SLOTS peaks of free space the slots reclaim what no job uses; below one
# peak a slot starts no new job, so a job never begins on a disk it would fill.
JOB_PEAK_GIB=18
ENGINE="${LINUX_RUNNER_ENGINE:-docker}"
VM_CPUS="${LINUX_RUNNER_VM_CPUS:-8}"
VM_MEMORY="${LINUX_RUNNER_VM_MEMORY:-16}"
VM_DISK="${LINUX_RUNNER_VM_DISK:-60}"
TOKEN_FILE="${LINUX_RUNNER_TOKEN_FILE:-}"
DAEMON_DIR="${LINUX_RUNNER_DAEMON_DIR:-/Library/LaunchDaemons}"
NEWSYSLOG_DIR="${LINUX_RUNNER_NEWSYSLOG_DIR:-/etc/newsyslog.d}"
LOG_FILE="${LINUX_RUNNER_LOG_FILE:-}"
# A test seam and a one-shot probe: stop each slot after this many jobs. Unset
# (the default) means forever.
MAX_JOBS="${LINUX_RUNNER_MAX_JOBS:-}"
BACKOFF_START=15
# How long a slot waits between looks at free space while it has too little to start a job.
SPACE_WAIT="${LINUX_RUNNER_SPACE_WAIT:-60}"
# How often a draining supervisor removes the runners that have no job.
DRAIN_INTERVAL="${LINUX_RUNNER_DRAIN_INTERVAL:-5}"
BACKOFF_MAX=300
AGENT_ID="com.autumngarage.linux-ephemeral-runner"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# log, die, need, the token file, the runner-group check, and just-in-time
# registration, shared with runner/macos-runner.sh.
# shellcheck source=runner/jit.sh
. "$here/jit.sh"
[ -f "$here/queue.sh" ] || die "queue.sh must sit beside linux-runner.sh (copy it with jit.sh)"
# The role policy, shared with runner/macos-runner.sh.
# shellcheck source=runner/queue.sh
. "$here/queue.sh"

vm_share="$HOME/.linux-runner-vm-share"
colima_config="$HOME/.colima/default/colima.yaml"
# A named supervisor keeps its slot records and drain marker apart from the
# host's default one, so stopping one never drains the other.
if [ -n "${LINUX_RUNNER_NAME:-}" ]; then
  case "$LINUX_RUNNER_NAME" in *[!A-Za-z0-9-]*) die "LINUX_RUNNER_NAME must be letters, digits and hyphens, not '$LINUX_RUNNER_NAME'" ;; esac
  host="$LINUX_RUNNER_NAME"
  state_dir="${LINUX_RUNNER_STATE_DIR:-$HOME/Library/Application Support/linux-ephemeral-runner-$LINUX_RUNNER_NAME}"
else
  host="$(hostname -s 2>/dev/null || hostname)"
  state_dir="${LINUX_RUNNER_STATE_DIR:-$HOME/Library/Application Support/linux-ephemeral-runner}"
fi
prefix="$LABEL-$host"
# This supervisor's runner and container names, whole: PREFIX-SLOT-EPOCH. A
# prefix match alone would also take a supervisor named PREFIX-something.
own_names="^$prefix-[0-9]+-[0-9]+\$"
# The engine's architecture label, set by cmd_run once the engine answers.
arch_label=""

case "$SLOTS" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_SLOTS must be a positive integer, not '$SLOTS'" ;; esac
case "$QUEUE_SLOTS" in '' | *[!0-9]*) die "LINUX_RUNNER_QUEUE_SLOTS must be a non-negative integer, not '$QUEUE_SLOTS'" ;; esac
[ "$QUEUE_SLOTS" -lt "$SLOTS" ] || die "LINUX_RUNNER_QUEUE_SLOTS ($QUEUE_SLOTS) must be fewer than LINUX_RUNNER_SLOTS ($SLOTS), or no pull request could run"
case "$JANITOR_INTERVAL" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_JANITOR_INTERVAL must be a positive integer of seconds, not '$JANITOR_INTERVAL'" ;; esac
case "$MAX_JOBS" in *[!0-9]*) die "LINUX_RUNNER_MAX_JOBS must be a non-negative integer, not '$MAX_JOBS'" ;; esac
case "$PIDS" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_PIDS must be a positive integer, not '$PIDS'" ;; esac
case "$VM_DISK" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_VM_DISK must be a positive integer of GiB, not '$VM_DISK'" ;; esac
case "$ENGINE" in docker | colima) ;; *) die "LINUX_RUNNER_ENGINE must be docker or colima, not '$ENGINE'" ;; esac
case "$JOB_DOCKER" in none | dind) ;; *) die "LINUX_RUNNER_DOCKER must be none or dind, not '$JOB_DOCKER'" ;; esac

# The Docker engine the slots run containers on. Docker Desktop lives in a
# login session, so a host with nobody logged in uses this user's Colima VM,
# started here if it is not running; its socket is named explicitly, so no
# docker context another tool set can redirect the slots.
ensure_engine() {
  need docker "install Docker Desktop, or the Docker CLI and Colima (brew install docker colima)"
  if [ "$ENGINE" = colima ]; then ensure_colima; fi
  [ "$JOB_DOCKER" = dind ] || return 0
  require_sysbox
}

# engine_arch_label: the label for the architecture the job containers run on,
# read from the engine rather than the host: a Mac's Colima VM is arm64 Linux.
engine_arch_label() {
  local arch
  arch="$(docker info --format '{{.Architecture}}' 2>/dev/null)" || die "the Docker engine does not answer"
  case "$arch" in
    x86_64 | amd64) echo linux-x64 ;;
    aarch64 | arm64) echo linux-arm64 ;;
    *) die "the Docker engine runs on '$arch', which has no runner label" ;;
  esac
}

ensure_colima() {
  need colima "install Colima (brew install colima)"
  export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
  # A VM that runs but whose engine does not answer is stopped first: the supervisor starts with
  # no job of its own running, so nothing is cut.
  if colima status >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
    log "the Colima VM runs but its engine does not answer; stopping it to start it again"
    colima stop --force || log "colima could not stop its VM; starting it anyway"
  fi
  # Colima rewrites Docker's daemon.json from its own configuration at every
  # start, so a dind VM's Sysbox runtime is declared there. A VM made without
  # it is refused, not patched: its next restart would drop the runtime.
  if [ "$JOB_DOCKER" = dind ]; then
    [ -f "$colima_config" ] || colima status >/dev/null 2>&1 || write_dind_colima_config
    grep -q 'sysbox-runc' "$colima_config" 2>/dev/null \
      || die "the Colima VM was made without the Sysbox runtime that dind jobs run under. Delete the VM as $(id -un) ('colima delete --data', which also drops the old engine's containers) so it is made again"
  fi
  if ! colima status >/dev/null 2>&1; then
    # --disk sizes a new VM only; an existing VM keeps the disk it was made with.
    log "starting the Colima VM (aarch64, $VM_CPUS CPUs, ${VM_MEMORY} GiB memory, ${VM_DISK} GiB disk for a new VM)"
    # Colima shares the user's home into a new VM unless told otherwise, and
    # the registration token lives there. The VM gets one empty folder instead.
    mkdir -p "$vm_share"
    if [ "$JOB_DOCKER" = dind ]; then
      # Flags would make Colima rewrite the configuration without the runtime.
      colima start || die "colima could not start its VM; see 'colima start' as $(id -un)"
    else
      colima start --vm-type vz --arch aarch64 --cpu "$VM_CPUS" --memory "$VM_MEMORY" --disk "$VM_DISK" \
        --mount "$vm_share" \
        || die "colima could not start its VM; see 'colima start' as $(id -un)"
    fi
  fi
  [ "$JOB_DOCKER" = dind ] || return 0
  # The VM holds nothing of the host's, as a second boundary behind Sysbox: an
  # existing VM made before the empty share is refused, not trusted.
  local shared
  shared="$(colima ssh -- cat /proc/mounts | awk '$3 ~ /^(virtiofs|9p|fuse\.sshfs)$/ {print $2}' | grep -vFx -- "$vm_share" || true)"
  [ -z "$shared" ] || die "the Colima VM shares host folders ($(printf '%s' "$shared" | tr '\n' ' ')); a dind job could read them. Delete the VM as $(id -un) ('colima delete --data') so it is made again with only $vm_share"
  # Installed over ssh once the VM is up, not by a boot-time provision script:
  # those run before the VM resolves names, and Colima ignores their failure.
  # A package whose setup failed leaves its binary behind, so the check is
  # dpkg's own state, not the binary.
  # shellcheck disable=SC2016
  if ! colima ssh -- sh -c 'test "$(dpkg-query -W -f="\${db:Status-Status}" sysbox-ce 2>/dev/null)" = installed' >/dev/null 2>&1; then
    log "installing Sysbox $SYSBOX_VERSION in the Colima VM"
    sysbox_install_script | colima ssh -- sudo sh -s \
      || die "Sysbox $SYSBOX_VERSION did not install in the Colima VM; see 'colima ssh' as $(id -un)"
    # Its package restarts the VM's Docker engine to add the runtime.
    local _
    for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
  fi
  # A VM whose Sysbox predates the data root would put every job's inner
  # Docker on its small root disk; it is refused, not patched.
  colima ssh -- sh -c "ps -o args= -C sysbox-mgr | grep -qF -- '--data-root $SYSBOX_DATA_ROOT'" >/dev/null 2>&1 \
    || die "Sysbox in the Colima VM keeps job data outside $SYSBOX_DATA_ROOT, on the VM's root disk. Delete the VM as $(id -un) ('colima delete --data') so it is made again"
}

# write_dind_colima_config: the whole configuration of a new dind VM. Colima
# fills every other setting with its defaults.
write_dind_colima_config() {
  mkdir -p "$(dirname "$colima_config")"
  cat >"$colima_config" <<YAML
# Written by linux-runner.sh for LINUX_RUNNER_DOCKER=dind. Started without
# flags, which would make Colima rewrite it without the Sysbox runtime.
cpu: $VM_CPUS
memory: $VM_MEMORY
disk: $VM_DISK
arch: aarch64
vmType: vz
runtime: docker
mounts:
  - location: $vm_share
    writable: false
docker:
  runtimes:
    sysbox-runc:
      path: /usr/bin/sysbox-runc
YAML
}

# sysbox_install_script: run as root in the VM; the package is verified before
# it is installed.
#
# Sysbox keeps each job's inner /var/lib/docker under its data root, which
# defaults to /var/lib/sysbox on the VM's 19 GiB root disk. Colima mounts the
# VM's data disk (VM_DISK) at /var/lib/docker, so the data root goes there,
# beside the outer engine's data, and three jobs' image builds share the disk
# sized for them. The drop-in is written before the package, whose setup
# starts sysbox-mgr.
#
# Space a job frees inside the VM returns to the Mac's disk only when the VM
# trims it, and Ubuntu's fstrim.timer runs weekly, so it runs hourly.
sysbox_install_script() {
  cat <<SH
set -eu
mkdir -p $SYSBOX_DATA_ROOT /etc/systemd/system/sysbox-mgr.service.d /etc/systemd/system/fstrim.timer.d
printf '[Service]\\nExecStart=\\nExecStart=/usr/bin/sysbox-mgr --data-root $SYSBOX_DATA_ROOT\\n' >/etc/systemd/system/sysbox-mgr.service.d/10-data-root.conf
printf '[Timer]\\nOnCalendar=\\nOnCalendar=hourly\\nRandomizedDelaySec=0\\n' >/etc/systemd/system/fstrim.timer.d/10-hourly.conf
systemctl daemon-reload
systemctl restart fstrim.timer
deb=/tmp/sysbox-ce_${SYSBOX_VERSION}.linux_arm64.deb
curl -fsSL --retry 5 --retry-connrefused -o "\$deb" https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}.linux_arm64.deb
echo "${SYSBOX_SHA256}  \$deb" | sha256sum -c -
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "\$deb"
SH
}

# require_sysbox: a dind job never starts on an engine that would run it
# without Sysbox, where --runtime would fail or, worse, need --privileged.
require_sysbox() {
  docker info --format '{{range $name, $_ := .Runtimes}}{{$name}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -qx sysbox-runc \
    || die "the Docker engine offers no sysbox-runc runtime, which dind jobs run under; install Sysbox $SYSBOX_VERSION (https://github.com/nestybox/sysbox) for this engine"
}

# engine_lost: whether this user's Colima engine stopped answering. A container that fails at
# once with the engine still answering is the job's or the image's fault, and only waits.
engine_lost() {
  [ "$ENGINE" = colima ] || return 1
  docker info >/dev/null 2>&1 && return 1
  sleep 5
  ! docker info >/dev/null 2>&1
}

# engine_free_gib: the space a job can still write, in GiB: the VM's data disk or, when the
# Mac has less, the Mac's own free space, because the VM disk is a sparse file that fails
# writes (corrupting the image store) once the Mac under it is full. Prints nothing when the
# engine is not a Colima VM or a reading fails; callers then do not gate on space.
engine_free_gib() {
  [ "$ENGINE" = colima ] || return 0
  local vm host
  vm="$(colima ssh -- df -k --output=avail /var/lib/docker 2>/dev/null | tail -n 1 | tr -d ' ')"
  host="$(df -k "$HOME" 2>/dev/null | awk 'NR == 2 {print $4}')"
  case "$vm$host" in '' | *[!0-9]*) return 0 ;; esac
  [ -n "$vm" ] && [ -n "$host" ] || return 0
  [ "$vm" -le "$host" ] || vm="$host"
  echo $((vm / 1048576))
}

# reclaim_engine_space: remove what no job uses and hand the freed blocks back to the Mac. The
# VM's data disk is a sparse file that grows with every job's writes and shrinks only when the
# VM trims them; three slots write more than 50 GB an hour, so waiting for the hourly
# fstrim.timer let the file fill the Mac's disk. What is removed:
#   - this host's exited job containers (their writable layers and volumes). Never a created
#     one, which is another slot's launch in progress, and never by force, so a container that
#     started meanwhile is refused, not killed;
#   - Sysbox's per-container data for a container that no longer exists. The directory list is
#     read before the container list, so a directory with no container is one whose container
#     was removed; a mounted one is never touched;
#   - dangling images and build cache, which nothing runs from (the job image is tagged).
# A plain Linux host frees its disk at once and has nothing to return. A failed step is
# logged and never fails the slot.
reclaim_engine_space() {
  [ "$ENGINE" = colima ] || return 0
  local out leftover
  docker ps -aq --filter "name=$own_names" --filter status=exited --filter status=dead |
    while read -r leftover; do docker rm -v "$leftover" >/dev/null 2>&1 || true; done
  docker image prune -f >/dev/null 2>&1 || log "slot $1: pruning dangling images failed"
  docker builder prune -f >/dev/null 2>&1 || log "slot $1: pruning the build cache failed"
  out="$(colima ssh -- sudo sh -c 'cd '"$SYSBOX_DATA_ROOT"'/docker 2>/dev/null || exit 0
    dirs=$(ls); ids=$(docker ps -aq --no-trunc)
    for d in $dirs; do
      case "$ids" in *"$d"*) continue ;; esac
      grep -qF "/$d" /proc/mounts && continue
      rm -rf "$d" && echo "removed Sysbox data of absent container $d"
    done' 2>&1)" || log "slot $1: removing Sysbox data of absent containers failed: $out"
  [ -z "$out" ] || log "slot $1: $out"
  out="$(colima ssh -- sudo fstrim -v /var/lib/docker 2>&1)" \
    || log "slot $1: trimming the VM's /var/lib/docker failed (the hourly fstrim.timer still returns the space): $out"
}

# free_note: " (N GiB free)" for a job's closing log line, empty when unknown.
free_note() {
  local free
  free="$(engine_free_gib)"
  [ -z "$free" ] || printf ' (%s GiB free for jobs)' "$free"
}

# wait_for_engine_space: a slot starts no job on less than one job's peak. It reclaims first
# when there is less than every slot's peak; space that stays short is said in the log, and
# running jobs ending is what frees more.
wait_for_engine_space() {
  local free tries=0
  free="$(engine_free_gib)"
  [ -n "$free" ] || return 0
  [ "$free" -ge $((SLOTS * JOB_PEAK_GIB)) ] || { reclaim_engine_space "$1"; free="$(engine_free_gib)"; }
  while [ -n "$free" ] && [ "$free" -lt "$JOB_PEAK_GIB" ] && [ ! -e "$state_dir/draining" ]; do
    [ $((tries % 10)) -ne 0 ] || log "slot $1: only ${free} GiB free for jobs on the VM disk or the Mac, less than a job's ${JOB_PEAK_GIB} GiB peak; no job starts until space frees"
    tries=$((tries + 1))
    sleep "$SPACE_WAIT"
    free="$(engine_free_gib)"
  done
}

run_slot() {
  local slot="$1" backoff="$BACKOFF_START" jobs=0
  local gid name jit id err role started rc
  while :; do
    if [ -n "$MAX_JOBS" ] && [ "$jobs" -ge "$MAX_JOBS" ]; then
      return 0
    fi
    if [ -e "$state_dir/draining" ]; then
      log "slot $slot: draining; registering nothing more"
      return 0
    fi
    # Before every registration, not once at start: the group is the
    # boundary, and it can be edited while the supervisor runs.
    if ! gid="$(group_id)"; then
      log "slot $slot: runner group '$GROUP' failed its check; registering nothing, retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    wait_for_engine_space "$slot"
    name="$prefix-$slot-$(date +%s)"
    rc=0
    register_runner "$slot" "$gid" "$name" || rc=$?
    if [ "$rc" -eq 2 ]; then
      log "slot $slot: draining; registering nothing more"
      return 0
    fi
    if [ "$rc" -ne 0 ]; then
      log "slot $slot: $err; retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    log "slot $slot: runner $name ($id) is waiting for a job ($role)"
    started="$(date +%s)"
    rc=0
    # The single-use configuration goes in on stdin, never as an argument:
    # macOS shows every user's process arguments to every other user, so on
    # a Mac shared with a persistent macOS runner, `docker run ... --jitconfig
    # <config>` would hand the runner credential to that runner's jobs for as
    # long as this job ran. Inside the container it becomes run.sh's argument,
    # visible only in the container's own VM.
    if [ "$JOB_DOCKER" = dind ]; then
      printf '%s\n' "$jit" | docker run --init -i --name "$name" \
        --memory "$MEMORY" --cpus "$CPUS" --pids-limit "$PIDS" --pull never \
        --runtime sysbox-runc --user root \
        "$IMAGE" /usr/local/bin/job-entry.sh || rc=$?
    else
      printf '%s\n' "$jit" | docker run --init -i --name "$name" \
        --memory "$MEMORY" --cpus "$CPUS" --pids-limit "$PIDS" --pull never \
        "$IMAGE" bash -c 'IFS= read -r jit && exec ./run.sh --jitconfig "$jit"' || rc=$?
    fi
    forget_runner "$id"
    docker rm -f -v "$name" >/dev/null 2>&1 || true
    reclaim_engine_space "$slot"
    rm -f "$state_dir/slot-$slot"
    jobs=$((jobs + 1))
    log "slot $slot: runner $name exited ($rc) after $(($(date +%s) - started))s$(free_note)"
    # A container that dies at once (a missing image, a daemon that is down)
    # would otherwise register and discard runners in a tight loop.
    if [ "$rc" -ne 0 ] && [ $(($(date +%s) - started)) -lt 30 ] && engine_lost; then
      # No job runs on an engine that is gone, so the supervisor stops at once. It exits
      # non-zero (cmd_run's end), so the daemon's KeepAlive {SuccessfulExit=false} starts it
      # again and its ensure_engine starts the VM.
      log "slot $slot: the container engine stopped answering; the supervisor stops with a failure so launchd starts it, and the engine, again"
      : >"$state_dir/engine-lost"
      kill -TERM "$supervisor" 2>/dev/null || true
      return 0
    fi
    if [ "$rc" -ne 0 ] && [ $(($(date +%s) - started)) -lt 30 ]; then
      log "slot $slot: the container failed immediately; retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
    else
      backoff="$BACKOFF_START"
    fi
  done
}

# The first stop signal drains: nothing new registers, the registrations that
# have no job are removed, and the jobs that run are left to finish, so a
# restart cuts none of them (AUT-2763). A cancelled merge-queue job evicts its
# entry and everything behind it. A second signal stops at once, and so does
# the service manager's kill once its exit timeout has passed.
drain_slots() {
  if [ -e "$state_dir/engine-lost" ]; then
    log "stopping at once: the container engine is gone, so no job is left to finish"
    stop_slots
    return
  fi
  # Only a stop that arrives here from outside is a clean end; cmd_run exits 0 for it alone.
  stop_requested=1
  trap stop_slots INT TERM
  until mkdir "$state_dir/register.lock" 2>/dev/null; do sleep 1; done
  : >"$state_dir/draining"
  rmdir "$state_dir/register.lock"
  log "stop requested: draining; running jobs finish first (signal again to stop at once)"
  drain_idle &
  drain_pid=$!
}

# drain_idle: until the supervisor is done, remove the registered runners that
# have no job. GitHub refuses to remove a runner that has one, and that
# refusal is what leaves it alone.
drain_idle() {
  local file id name busy
  while [ -e "$state_dir/draining" ]; do
    for file in "$state_dir"/slot-*; do
      [ -f "$file" ] || continue
      read -r id name _ <"$file" || continue
      busy="$(gh api "orgs/$ORG/actions/runners/$id" --jq .busy 2>/dev/null)" || continue
      [ "$busy" = false ] || continue
      gh api -X DELETE "orgs/$ORG/actions/runners/$id" >/dev/null 2>&1 || true
    done
    sleep "$DRAIN_INTERVAL"
  done
}

# On stop, take down this host's job containers and the registrations that
# have not taken a job yet, so nothing is left waiting for work.
stop_slots() {
  local file id name
  trap - INT TERM
  for file in "$state_dir"/slot-*; do
    [ -f "$file" ] || continue
    read -r id name _ <"$file" || true
    docker rm -f -v "$name" >/dev/null 2>&1 || true
    forget_runner "$id"
    rm -f "$file"
  done
  kill 0 2>/dev/null || true
}

# The janitor, once at start, before any slot registers: every offline runner
# named for this host is a registration a killed supervisor left, which would
# otherwise sit in the group until GitHub expires it.
forget_stale_runners() {
  local ids id
  if ! ids="$(gh api --paginate "orgs/$ORG/actions/runners" \
    --jq ".runners[] | select(.status == \"offline\" and (.name | test(\"$own_names\"))) | .id")"; then
    log "could not list $ORG's runners; stale registrations of $prefix stay until GitHub expires them"
    return 0
  fi
  for id in $ids; do
    if gh api -X DELETE "orgs/$ORG/actions/runners/$id" >/dev/null 2>&1; then
      log "removed stale offline registration $id"
    else
      log "could not remove stale offline registration $id; GitHub expires it in time"
    fi
  done
}

cmd_run() {
  local gid slot pid pids drain_pid="" janitor_pid=""
  stop_requested=""
  # The process a slot stops when the engine is gone; $$ is the supervisor in every slot.
  supervisor=$$
  if [ -n "$LOG_FILE" ]; then
    # Reopen the log for every line. newsyslog rotates it by renaming and
    # compressing it, and a descriptor held open across that would keep
    # writing into the renamed, then deleted, file until the next restart.
    # The writer ignores stop signals and ends when the supervisor does, so a
    # drain's own messages still arrive.
    exec > >(
      trap '' INT TERM
      while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" >>"$LOG_FILE"
      done
    ) 2>&1
  fi
  if [ -n "${LINUX_RUNNER_CACHE_SEED:-}" ]; then
    log "LINUX_RUNNER_CACHE_SEED is retired and ignored; every job starts from $IMAGE"
  fi
  ensure_engine
  arch_label="$(engine_arch_label)"
  # Every registration carries its architecture; jobs that need the other one
  # are no demand for this host's roles.
  RUNNER_EXTRA_LABEL="$arch_label"
  DEMAND_SKIP_LABEL=""
  [ "$arch_label" = linux-x64 ] || DEMAND_SKIP_LABEL=linux-x64
  need gh "install the GitHub CLI and log in with admin:org"
  need jq "install jq"
  load_token
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "image $IMAGE is missing; run 'bash runner/linux-runner.sh build' first"
  gid="$(group_id)"
  mkdir -p "$state_dir"
  # What a supervisor that was killed left: its jobs' containers, its slot
  # records and lock, and its registrations.
  docker ps -aq --filter "name=$own_names" | while read -r leftover; do
    docker rm -f -v "$leftover" >/dev/null 2>&1 || true
  done
  rm -f "$state_dir"/slot-* "$state_dir/draining" "$state_dir/engine-lost"
  rmdir "$state_dir/register.lock" 2>/dev/null || true
  forget_stale_runners
  trap drain_slots INT TERM
  if [ "$QUEUE_SLOTS" -gt 0 ]; then can_read_runs "$gid"; fi
  log "supervising $SLOTS slot(s), $QUEUE_SLOTS kept ready for the merge queue, for label $LABEL in $ORG runner group $GROUP ($gid)"
  slot=1
  pids=""
  while [ "$slot" -le "$SLOTS" ]; do
    run_slot "$slot" &
    pids="$pids $!"
    slot=$((slot + 1))
  done
  if [ "$QUEUE_SLOTS" -gt 0 ]; then
    janitor "$gid" &
    janitor_pid=$!
  fi
  # A trapped signal ends a wait early; the slots are done when their
  # processes are.
  for pid in $pids; do
    while kill -0 "$pid" 2>/dev/null; do wait "$pid" || true; done
  done
  if [ -n "$drain_pid" ]; then kill "$drain_pid" 2>/dev/null || true; fi
  if [ -n "$janitor_pid" ]; then
    pkill -P "$janitor_pid" 2>/dev/null || true
    kill "$janitor_pid" 2>/dev/null || true
    wait "$janitor_pid" 2>/dev/null || true
  fi
  rm -f "$state_dir/draining"
  # The service is kept alive only after a failure (KeepAlive {SuccessfulExit=false}), so
  # slots that end on their own, or an engine that is gone, must not look like a clean stop.
  # A run bounded by LINUX_RUNNER_MAX_JOBS is the tests' deliberate end.
  if [ -e "$state_dir/engine-lost" ] || { [ -z "$stop_requested" ] && [ -z "$MAX_JOBS" ]; }; then
    log "every slot ended without a stop request; exiting with a failure so the service manager restarts the supervisor"
    return 1
  fi
}

cmd_build() {
  ensure_engine
  docker build -t "$IMAGE" -f "$here/Dockerfile" "$here"
}

daemon_plist_path() { printf '%s/%s.plist\n' "$DAEMON_DIR" "$AGENT_ID"; }
newsyslog_path() { printf '%s/linux-ephemeral-runner.conf\n' "$NEWSYSLOG_DIR"; }

# The fleet at boot, as USER, with no login session: a LaunchDaemon (launchd
# starts it before anyone logs in, and keeps it alive) runs a copy of this
# script as USER, on USER's Colima VM, with USER's token file. USER should be
# an account that runs nothing else, so the token that registers runners is
# readable by no CI job on the Mac. Build the image as USER first.
cmd_install_daemon() {
  local user="${1:-}" home group user_state token installed plist rotation log_dir log_file launchd_log path_value
  [ -n "$user" ] || die "usage: sudo bash runner/linux-runner.sh install-daemon USER"
  need launchctl "install-daemon needs macOS launchd"
  [ "$(id -u)" -eq 0 ] || die "install-daemon writes $DAEMON_DIR; run it with sudo"
  home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$home" ] && [ -d "$home" ] || die "no local user '$user' with a home directory"
  group="$(id -gn "$user")"
  user_state="$home/Library/Application Support/linux-ephemeral-runner"
  token="$user_state/github-token"
  [ -f "$token" ] || die "no token for $user at $token; as $user, write a token that can manage the organization's self-hosted runners there, mode 600"
  [ "$(file_owner "$token")" = "$user" ] \
    || die "$token must belong to $user"
  case "$(file_mode "$token")" in
    600 | 400) ;;
    *) die "$token must be private to $user: chmod 600 it" ;;
  esac
  # A copy, so a checkout that later switches branches cannot change what runs.
  installed="$user_state/linux-runner.sh"
  cp "$here/linux-runner.sh" "$installed"
  cp "$here/jit.sh" "$here/queue.sh" "$user_state/"
  chown "$user:$group" "$installed" "$user_state/jit.sh" "$user_state/queue.sh"
  log_dir="$home/Library/Logs"
  mkdir -p "$log_dir"
  chown "$user:$group" "$log_dir"
  log_file="$log_dir/linux-ephemeral-runner.log"
  # launchd holds this one open; only what precedes run's own log lands here.
  launchd_log="$log_dir/linux-ephemeral-runner.launchd.log"
  # Homebrew's two prefixes first, so colima, docker, gh and jq resolve without
  # a login shell.
  path_value="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  plist="$(daemon_plist_path)"
  mkdir -p "$DAEMON_DIR"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_ID</string>
  <key>UserName</key><string>$user</string>
  <key>GroupName</key><string>$group</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$installed</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$home</string>
    <key>PATH</key><string>$path_value</string>
    <key>LINUX_RUNNER_ENGINE</key><string>colima</string>
    <key>LINUX_RUNNER_VM_CPUS</key><string>$VM_CPUS</string>
    <key>LINUX_RUNNER_VM_MEMORY</key><string>$VM_MEMORY</string>
    <key>LINUX_RUNNER_VM_DISK</key><string>$VM_DISK</string>
    <key>LINUX_RUNNER_TOKEN_FILE</key><string>$token</string>
    <key>LINUX_RUNNER_STATE_DIR</key><string>$user_state</string>
    <key>LINUX_RUNNER_ORG</key><string>$ORG</string>
    <key>LINUX_RUNNER_GROUP</key><string>$GROUP</string>
    <key>LINUX_RUNNER_SLOTS</key><string>$SLOTS</string>
    <key>LINUX_RUNNER_QUEUE_SLOTS</key><string>$QUEUE_SLOTS</string>
    <key>LINUX_RUNNER_MEMORY</key><string>$MEMORY</string>
    <key>LINUX_RUNNER_CPUS</key><string>$CPUS</string>
    <key>LINUX_RUNNER_PIDS</key><string>$PIDS</string>
    <key>LINUX_RUNNER_IMAGE</key><string>$IMAGE</string>
    <key>LINUX_RUNNER_DOCKER</key><string>$JOB_DOCKER</string>
    <key>LINUX_RUNNER_LOG_FILE</key><string>$log_file</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>ExitTimeOut</key><integer>5400</integer>
  <key>StandardOutPath</key><string>$launchd_log</string>
  <key>StandardErrorPath</key><string>$launchd_log</string>
</dict>
</plist>
EOF
  chown root:wheel "$plist"
  chmod 644 "$plist"
  # The log's rotation, the rule the owner first installed by hand: five
  # bzip2'd generations of 10 MiB, no signal to the daemon. Rewritten whole,
  # so installing again changes nothing.
  rotation="$(newsyslog_path)"
  mkdir -p "$NEWSYSLOG_DIR"
  printf '%s %s:staff 644 5 10240 * NJ\n' "$log_file" "$user" >"$rotation"
  chown root:wheel "$rotation"
  chmod 644 "$rotation"
  replace_service system "$AGENT_ID" "$plist" "the fleet"
  log "installed $AGENT_ID as $user; logs in $log_file, rotated by $rotation"
}

# The daemon stopped, its running jobs first allowed to finish, and left
# installed: the fleet's rebuild runs this before it deletes the VM.
cmd_stop_daemon() {
  need launchctl "stop-daemon needs macOS launchd"
  [ "$(id -u)" -eq 0 ] || die "stop-daemon stops a LaunchDaemon; run it with sudo"
  stop_service system "$AGENT_ID" "$(daemon_plist_path)"
}

cmd_uninstall_daemon() {
  need launchctl "uninstall-daemon needs macOS launchd"
  [ "$(id -u)" -eq 0 ] || die "uninstall-daemon removes a LaunchDaemon; run it with sudo"
  stop_service system "$AGENT_ID" "$(daemon_plist_path)"
  rm -f "$(daemon_plist_path)" "$(newsyslog_path)"
  log "removed $AGENT_ID from $DAEMON_DIR and its log rotation"
}

cmd_status() {
  if command -v launchctl >/dev/null 2>&1; then
    launchctl print "system/$AGENT_ID" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) =' \
      || echo "the daemon $AGENT_ID is not loaded"
  fi
  docker ps --filter "name=$own_names" --format '{{.Names}}  {{.Status}}'
  gh api --paginate "orgs/$ORG/actions/runners" \
    --jq ".runners[] | select(any(.labels[]; .name == \"$LABEL\")) | \"\(.name)  \(.status)  busy=\(.busy)\""
}

case "${1:-}" in
  build) cmd_build ;;
  run) cmd_run ;;
  install-daemon) cmd_install_daemon "${2:-}" ;;
  stop-daemon) cmd_stop_daemon ;;
  uninstall-daemon) cmd_uninstall_daemon ;;
  status) cmd_status ;;
  *)
    sed -n '3,/^# Runs under macOS/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
