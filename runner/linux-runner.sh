#!/usr/bin/env bash
#
# runner/linux-runner.sh -- keep single-use self-hosted Linux runners for the
# required workflows: one throwaway container per job (AUT-1596).
#
# Usage:
#   bash runner/linux-runner.sh build       build the job image from runner/Dockerfile
#   bash runner/linux-runner.sh run         supervise the runner slots in the foreground
#   bash runner/linux-runner.sh install     run them from a macOS LaunchAgent, kept awake
#   bash runner/linux-runner.sh uninstall   stop and remove the LaunchAgent
#   sudo bash runner/linux-runner.sh install-daemon USER
#                                           run them at boot as USER from a
#                                           LaunchDaemon, with no login session
#   sudo bash runner/linux-runner.sh uninstall-daemon
#                                           stop and remove the LaunchDaemon
#   bash runner/linux-runner.sh status      show the agent, containers, and registrations
#
# Each slot asks GitHub for a just-in-time runner configuration, which
# registers a runner for exactly one job, starts a fresh container from the
# job image with that configuration, and waits for it to exit. The container
# receives the single-use configuration and nothing else: no volume, no Docker
# socket, no host network, no credential. Nothing a job does outlives its
# container, which is what lets `validate` -- it runs the candidate's declared
# commands -- use these runners at all (see "Runner" in README.md).
#
# Configuration, from the environment (defaults in parentheses):
#   LINUX_RUNNER_ORG      organization (autumngarage)
#   LINUX_RUNNER_GROUP    runner group, restricted to the private consumers (linux-ephemeral)
#   LINUX_RUNNER_LABEL    the label the LINUX_RUNNER variable names (linux-ephemeral)
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
#   LINUX_RUNNER_TOKEN_FILE  a file holding the GitHub token gh uses, read when
#                         GH_TOKEN is unset; it must be readable by its owner
#                         only. A daemon has no login keychain, so this is its
#                         credential (unset: gh's own login)
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
LABEL="${LINUX_RUNNER_LABEL:-linux-ephemeral}"
SLOTS="${LINUX_RUNNER_SLOTS:-2}"
MEMORY="${LINUX_RUNNER_MEMORY:-6g}"
CPUS="${LINUX_RUNNER_CPUS:-4}"
PIDS="${LINUX_RUNNER_PIDS:-4096}"
IMAGE="${LINUX_RUNNER_IMAGE:-linux-ephemeral-runner:local}"
ENGINE="${LINUX_RUNNER_ENGINE:-docker}"
VM_CPUS="${LINUX_RUNNER_VM_CPUS:-8}"
VM_MEMORY="${LINUX_RUNNER_VM_MEMORY:-16}"
TOKEN_FILE="${LINUX_RUNNER_TOKEN_FILE:-}"
DAEMON_DIR="${LINUX_RUNNER_DAEMON_DIR:-/Library/LaunchDaemons}"
# A test seam and a one-shot probe: stop each slot after this many jobs. Unset
# (the default) means forever.
MAX_JOBS="${LINUX_RUNNER_MAX_JOBS:-}"
BACKOFF_START=15
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
case "$MAX_JOBS" in *[!0-9]*) die "LINUX_RUNNER_MAX_JOBS must be a non-negative integer, not '$MAX_JOBS'" ;; esac
case "$PIDS" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_PIDS must be a positive integer, not '$PIDS'" ;; esac
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
    log "starting the Colima VM ($VM_CPUS CPUs, ${VM_MEMORY} GiB)"
    colima start --vm-type vz --cpu "$VM_CPUS" --memory "$VM_MEMORY" \
      || die "colima could not start its VM; see 'colima start' as $(id -un)"
  fi
  export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
}

run_slot() {
  local slot="$1" backoff="$BACKOFF_START" jobs=0
  local gid name response jit id started rc
  while :; do
    if [ -n "$MAX_JOBS" ] && [ "$jobs" -ge "$MAX_JOBS" ]; then
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
    if ! response="$(request_jit "$name" "$gid")"; then
      log "slot $slot: could not register a runner ($response); retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    jit="$(printf '%s' "$response" | jq -r '.encoded_jit_config // empty')"
    id="$(printf '%s' "$response" | jq -r '.runner.id // empty')"
    if [ -z "$jit" ] || [ -z "$id" ]; then
      log "slot $slot: GitHub returned no runner configuration; retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    printf '%s %s\n' "$id" "$name" >"$state_dir/slot-$slot"
    log "slot $slot: runner $name ($id) is waiting for a job"
    started="$(date +%s)"
    rc=0
    # The single-use configuration goes in on stdin, never as an argument:
    # macOS shows every user's process arguments to every other user, so on
    # a Mac shared with a persistent macOS runner, `docker run ... --jitconfig
    # <config>` would hand the runner credential to that runner's jobs for as
    # long as this job ran. Inside the container it becomes run.sh's argument,
    # visible only in the container's own VM.
    printf '%s\n' "$jit" | docker run --rm --init -i --name "$name" \
      --memory "$MEMORY" --cpus "$CPUS" --pids-limit "$PIDS" --pull never \
      "$IMAGE" bash -c 'IFS= read -r jit && exec ./run.sh --jitconfig "$jit"' || rc=$?
    forget_runner "$id"
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

# On stop, take down this host's job containers and the registrations that
# have not taken a job yet, so nothing is left waiting for work.
stop_slots() {
  local file id name
  trap - INT TERM
  for file in "$state_dir"/slot-*; do
    [ -f "$file" ] || continue
    read -r id name <"$file" || true
    docker rm -f "$name" >/dev/null 2>&1 || true
    forget_runner "$id"
    rm -f "$file"
  done
  kill 0 2>/dev/null || true
}

cmd_run() {
  local gid slot
  ensure_engine
  need gh "install the GitHub CLI and log in with admin:org"
  need jq "install jq"
  load_token
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "image $IMAGE is missing; run 'bash runner/linux-runner.sh build' first"
  gid="$(group_id)"
  mkdir -p "$state_dir"
  trap stop_slots INT TERM
  log "supervising $SLOTS slot(s) for label $LABEL in $ORG runner group $GROUP ($gid)"
  slot=1
  while [ "$slot" -le "$SLOTS" ]; do
    run_slot "$slot" &
    slot=$((slot + 1))
  done
  wait
}

cmd_build() {
  ensure_engine
  docker build -t "$IMAGE" -f "$here/Dockerfile" "$here"
}

plist_path() { printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$AGENT_ID"; }

cmd_install() {
  local installed plist log_file path_value
  need launchctl "install needs macOS launchd"
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "image $IMAGE is missing; run 'bash runner/linux-runner.sh build' first"
  group_id >/dev/null
  mkdir -p "$state_dir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  # A copy, so a checkout that later switches branches cannot change what runs.
  installed="$state_dir/linux-runner.sh"
  cp "$here/linux-runner.sh" "$installed"
  cp "$here/jit.sh" "$state_dir/jit.sh"
  plist="$(plist_path)"
  log_file="$HOME/Library/Logs/linux-ephemeral-runner.log"
  path_value="$(dirname "$(command -v docker)"):$(dirname "$(command -v gh)"):$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-i</string>
    <string>/bin/bash</string>
    <string>$installed</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$path_value</string>
    <key>LINUX_RUNNER_ORG</key><string>$ORG</string>
    <key>LINUX_RUNNER_GROUP</key><string>$GROUP</string>
    <key>LINUX_RUNNER_LABEL</key><string>$LABEL</string>
    <key>LINUX_RUNNER_SLOTS</key><string>$SLOTS</string>
    <key>LINUX_RUNNER_MEMORY</key><string>$MEMORY</string>
    <key>LINUX_RUNNER_CPUS</key><string>$CPUS</string>
    <key>LINUX_RUNNER_PIDS</key><string>$PIDS</string>
    <key>LINUX_RUNNER_IMAGE</key><string>$IMAGE</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$log_file</string>
  <key>StandardErrorPath</key><string>$log_file</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" \
    || die "launchctl could not load $plist"
  log "installed $AGENT_ID; logs in $log_file"
}

cmd_uninstall() {
  need launchctl "uninstall needs macOS launchd"
  launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
  rm -f "$(plist_path)"
  log "removed $AGENT_ID"
}

daemon_plist_path() { printf '%s/%s.plist\n' "$DAEMON_DIR" "$AGENT_ID"; }

# The fleet at boot, as USER, with no login session: a LaunchDaemon (launchd
# starts it before anyone logs in, and keeps it alive) runs a copy of this
# script as USER, on USER's Colima VM, with USER's token file. USER should be
# an account that runs nothing else, so the token that registers runners is
# readable by no CI job on the Mac. Build the image as USER first.
cmd_install_daemon() {
  local user="${1:-}" home group user_state token installed plist log_dir log_file path_value
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
  cp "$here/jit.sh" "$user_state/jit.sh"
  chown "$user:$group" "$installed" "$user_state/jit.sh"
  log_dir="$home/Library/Logs"
  mkdir -p "$log_dir"
  chown "$user:$group" "$log_dir"
  log_file="$log_dir/linux-ephemeral-runner.log"
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
    <key>LINUX_RUNNER_TOKEN_FILE</key><string>$token</string>
    <key>LINUX_RUNNER_STATE_DIR</key><string>$user_state</string>
    <key>LINUX_RUNNER_ORG</key><string>$ORG</string>
    <key>LINUX_RUNNER_GROUP</key><string>$GROUP</string>
    <key>LINUX_RUNNER_LABEL</key><string>$LABEL</string>
    <key>LINUX_RUNNER_SLOTS</key><string>$SLOTS</string>
    <key>LINUX_RUNNER_MEMORY</key><string>$MEMORY</string>
    <key>LINUX_RUNNER_CPUS</key><string>$CPUS</string>
    <key>LINUX_RUNNER_PIDS</key><string>$PIDS</string>
    <key>LINUX_RUNNER_IMAGE</key><string>$IMAGE</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$log_file</string>
  <key>StandardErrorPath</key><string>$log_file</string>
</dict>
</plist>
EOF
  chown root:wheel "$plist"
  chmod 644 "$plist"
  launchctl bootout "system/$AGENT_ID" >/dev/null 2>&1 || true
  launchctl bootstrap system "$plist" \
    || die "launchctl could not load $plist"
  log "installed $AGENT_ID as $user; logs in $log_file"
}

cmd_uninstall_daemon() {
  need launchctl "uninstall-daemon needs macOS launchd"
  [ "$(id -u)" -eq 0 ] || die "uninstall-daemon removes a LaunchDaemon; run it with sudo"
  launchctl bootout "system/$AGENT_ID" >/dev/null 2>&1 || true
  rm -f "$(daemon_plist_path)"
  log "removed $AGENT_ID from $DAEMON_DIR"
}

cmd_status() {
  if command -v launchctl >/dev/null 2>&1; then
    launchctl print "gui/$(id -u)/$AGENT_ID" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) =' \
      || launchctl print "system/$AGENT_ID" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) =' \
      || echo "neither the agent nor the daemon $AGENT_ID is loaded"
  fi
  docker ps --filter "name=$prefix-" --format '{{.Names}}  {{.Status}}'
  gh api --paginate "orgs/$ORG/actions/runners" \
    --jq ".runners[] | select(any(.labels[]; .name == \"$LABEL\")) | \"\(.name)  \(.status)  busy=\(.busy)\""
}

case "${1:-}" in
  build) cmd_build ;;
  run) cmd_run ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  install-daemon) cmd_install_daemon "${2:-}" ;;
  uninstall-daemon) cmd_uninstall_daemon ;;
  status) cmd_status ;;
  *)
    sed -n '3,/^# Runs under macOS/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
