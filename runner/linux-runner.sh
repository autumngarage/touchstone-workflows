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
#   sudo bash runner/linux-runner.sh uninstall-daemon
#                                           stop and remove the LaunchDaemon
#   bash runner/linux-runner.sh status      show the daemon, containers, and registrations
#
# The model is deliberately simple: N identical slots, one job each. Every
# runner registers with the same labels (self-hosted, linux-ephemeral), so any
# slot takes any job routed here. Routing is static: validate.yml selects
# ["self-hosted","linux-ephemeral"] when a repository's LINUX_PR_RUNNER or
# LINUX_QUEUE_RUNNER variable says `local` (see "Runner" in README.md). There
# are no slot roles, no watcher, no overflow, and no cache images.
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
#   LINUX_RUNNER_SLOTS    jobs run at once (2)
#   LINUX_RUNNER_MEMORY   memory limit per job container (6g)
#   LINUX_RUNNER_CPUS     CPU limit per job container (4)
#   LINUX_RUNNER_PIDS     process limit per job container (4096): a pull
#                         request that forks without end exhausts its own
#                         container, not the VM every slot shares
#   LINUX_RUNNER_IMAGE    job image tag (linux-ephemeral-runner:local)
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
# Retired, still accepted because an installed wrapper may pass them:
#   LINUX_RUNNER_QUEUE_SLOTS  merge-queue slot roles. 0 or unset is accepted;
#                         any other value is refused, since no slot has a role
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
MEMORY="${LINUX_RUNNER_MEMORY:-6g}"
CPUS="${LINUX_RUNNER_CPUS:-4}"
PIDS="${LINUX_RUNNER_PIDS:-4096}"
IMAGE="${LINUX_RUNNER_IMAGE:-linux-ephemeral-runner:local}"
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
# How often a draining supervisor removes the runners that have no job.
DRAIN_INTERVAL="${LINUX_RUNNER_DRAIN_INTERVAL:-5}"
BACKOFF_MAX=300
AGENT_ID="com.autumngarage.linux-ephemeral-runner"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# log, die, need, the token file, the runner-group check, and just-in-time
# registration, shared with runner/macos-runner.sh.
# shellcheck source=runner/jit.sh
. "$here/jit.sh"

state_dir="${LINUX_RUNNER_STATE_DIR:-$HOME/Library/Application Support/linux-ephemeral-runner}"
host="$(hostname -s 2>/dev/null || hostname)"
prefix="$LABEL-$host"

case "$SLOTS" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_SLOTS must be a positive integer, not '$SLOTS'" ;; esac
case "${LINUX_RUNNER_QUEUE_SLOTS:-0}" in
  0) ;;
  *) die "LINUX_RUNNER_QUEUE_SLOTS is retired: every slot is identical and takes any job. Set it to 0 or unset it, not '$LINUX_RUNNER_QUEUE_SLOTS'" ;;
esac
case "$MAX_JOBS" in *[!0-9]*) die "LINUX_RUNNER_MAX_JOBS must be a non-negative integer, not '$MAX_JOBS'" ;; esac
case "$PIDS" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_PIDS must be a positive integer, not '$PIDS'" ;; esac
case "$VM_DISK" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_VM_DISK must be a positive integer of GiB, not '$VM_DISK'" ;; esac
case "$ENGINE" in docker | colima) ;; *) die "LINUX_RUNNER_ENGINE must be docker or colima, not '$ENGINE'" ;; esac

# The Docker engine the slots run containers on. Docker Desktop lives in a
# login session, so a host with nobody logged in uses this user's Colima VM,
# started here if it is not running; its socket is named explicitly, so no
# docker context another tool set can redirect the slots.
ensure_engine() {
  need docker "install Docker Desktop, or the Docker CLI and Colima (brew install docker colima)"
  [ "$ENGINE" = colima ] || return 0
  need colima "install Colima (brew install colima)"
  if ! colima status >/dev/null 2>&1; then
    # --disk sizes a new VM only; an existing VM keeps the disk it was made with.
    log "starting the Colima VM (aarch64, $VM_CPUS CPUs, ${VM_MEMORY} GiB memory, ${VM_DISK} GiB disk for a new VM)"
    colima start --vm-type vz --arch aarch64 --cpu "$VM_CPUS" --memory "$VM_MEMORY" --disk "$VM_DISK" \
      || die "colima could not start its VM; see 'colima start' as $(id -un)"
  fi
  export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
}

# register_runner SLOT GID NAME: register runner NAME for one job and write the
# slot's state file, under the lock the drain takes to set its marker, so a
# slot either registers before the drain and the drain sees its runner, or
# sees the marker and registers nothing. Sets jit and id in the caller; on
# failure sets err and returns 1, and returns 2 when the supervisor is
# draining.
register_runner() {
  local slot="$1" gid="$2" name="$3" lock="$state_dir/register.lock" response
  jit="" id="" err=""
  until mkdir "$lock" 2>/dev/null; do sleep 1; done
  if [ -e "$state_dir/draining" ]; then
    rmdir "$lock"
    return 2
  fi
  if ! response="$(request_jit "$name" "$gid")"; then
    err="could not register a runner ($response)"
    rmdir "$lock"
    return 1
  fi
  jit="$(printf '%s' "$response" | jq -r '.encoded_jit_config // empty')"
  id="$(printf '%s' "$response" | jq -r '.runner.id // empty')"
  if [ -z "$jit" ] || [ -z "$id" ]; then
    err="GitHub returned no runner configuration"
    rmdir "$lock"
    return 1
  fi
  printf '%s %s\n' "$id" "$name" >"$state_dir/slot-$slot"
  rmdir "$lock"
}

run_slot() {
  local slot="$1" backoff="$BACKOFF_START" jobs=0
  local gid name jit id err started rc
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
    log "slot $slot: runner $name ($id) is waiting for a job"
    started="$(date +%s)"
    rc=0
    # The single-use configuration goes in on stdin, never as an argument:
    # macOS shows every user's process arguments to every other user, so on
    # a Mac shared with a persistent macOS runner, `docker run ... --jitconfig
    # <config>` would hand the runner credential to that runner's jobs for as
    # long as this job ran. Inside the container it becomes run.sh's argument,
    # visible only in the container's own VM.
    printf '%s\n' "$jit" | docker run --init -i --name "$name" \
      --memory "$MEMORY" --cpus "$CPUS" --pids-limit "$PIDS" --pull never \
      "$IMAGE" bash -c 'IFS= read -r jit && exec ./run.sh --jitconfig "$jit"' || rc=$?
    forget_runner "$id"
    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -f "$state_dir/slot-$slot"
    jobs=$((jobs + 1))
    log "slot $slot: runner $name exited ($rc) after $(($(date +%s) - started))s"
    # A container that dies at once (a missing image, a daemon that is down)
    # would otherwise register and discard runners in a tight loop.
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
    docker rm -f "$name" >/dev/null 2>&1 || true
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
    --jq ".runners[] | select(.status == \"offline\" and (.name | startswith(\"$prefix-\"))) | .id")"; then
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
  local gid slot pid pids drain_pid=""
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
  need gh "install the GitHub CLI and log in with admin:org"
  need jq "install jq"
  load_token
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "image $IMAGE is missing; run 'bash runner/linux-runner.sh build' first"
  gid="$(group_id)"
  mkdir -p "$state_dir"
  # What a supervisor that was killed left: its jobs' containers, its slot
  # records and lock, and its registrations.
  docker ps -aq --filter "name=^$prefix-" | while read -r leftover; do
    docker rm -f "$leftover" >/dev/null 2>&1 || true
  done
  rm -f "$state_dir"/slot-* "$state_dir/draining"
  rmdir "$state_dir/register.lock" 2>/dev/null || true
  forget_stale_runners
  trap drain_slots INT TERM
  log "supervising $SLOTS identical slot(s) for label $LABEL in $ORG runner group $GROUP ($gid)"
  slot=1
  pids=""
  while [ "$slot" -le "$SLOTS" ]; do
    run_slot "$slot" &
    pids="$pids $!"
    slot=$((slot + 1))
  done
  # A trapped signal ends a wait early; the slots are done when their
  # processes are.
  for pid in $pids; do
    while kill -0 "$pid" 2>/dev/null; do wait "$pid" || true; done
  done
  if [ -n "$drain_pid" ]; then kill "$drain_pid" 2>/dev/null || true; fi
  rm -f "$state_dir/draining"
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
  cp "$here/jit.sh" "$user_state/"
  chown "$user:$group" "$installed" "$user_state/jit.sh"
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
    <key>LINUX_RUNNER_MEMORY</key><string>$MEMORY</string>
    <key>LINUX_RUNNER_CPUS</key><string>$CPUS</string>
    <key>LINUX_RUNNER_PIDS</key><string>$PIDS</string>
    <key>LINUX_RUNNER_IMAGE</key><string>$IMAGE</string>
    <key>LINUX_RUNNER_LOG_FILE</key><string>$log_file</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
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

cmd_uninstall_daemon() {
  need launchctl "uninstall-daemon needs macOS launchd"
  [ "$(id -u)" -eq 0 ] || die "uninstall-daemon removes a LaunchDaemon; run it with sudo"
  launchctl bootout "system/$AGENT_ID" >/dev/null 2>&1 || true
  rm -f "$(daemon_plist_path)" "$(newsyslog_path)"
  log "removed $AGENT_ID from $DAEMON_DIR and its log rotation"
}

cmd_status() {
  if command -v launchctl >/dev/null 2>&1; then
    launchctl print "system/$AGENT_ID" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) =' \
      || echo "the daemon $AGENT_ID is not loaded"
  fi
  docker ps --filter "name=$prefix-" --format '{{.Names}}  {{.Status}}'
  gh api --paginate "orgs/$ORG/actions/runners" \
    --jq ".runners[] | select(any(.labels[]; .name == \"$LABEL\")) | \"\(.name)  \(.status)  busy=\(.busy)\""
}

case "${1:-}" in
  build) cmd_build ;;
  run) cmd_run ;;
  install-daemon) cmd_install_daemon "${2:-}" ;;
  uninstall-daemon) cmd_uninstall_daemon ;;
  status) cmd_status ;;
  *)
    sed -n '3,/^# Runs under macOS/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
