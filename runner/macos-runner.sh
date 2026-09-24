#!/usr/bin/env bash
#
# runner/macos-runner.sh -- keep a pool of single-use macOS runners in one CI
# account's login session (AUT-2013).
#
# Usage:
#   sudo bash runner/macos-runner.sh run        supervise the pool's slots in the foreground
#   sudo bash runner/macos-runner.sh install-daemon
#                                               run them at boot from a LaunchDaemon
#   sudo bash runner/macos-runner.sh uninstall-daemon
#                                               stop and remove the LaunchDaemon
#   sudo bash runner/macos-runner.sh status     show the daemon, the slots, and their runners
#
# The CI account (MACOS_RUNNER_USER) already runs one persistent runner,
# registered by hand in ~USER/actions-runner. It keeps its own name label, and
# work that must not overlap itself in the account selects that name: cleanup
# that stops the account's processes (hesperus), and the smoke, whose macOS
# grants belong to that runner. This supervisor keeps pool slots beside it.
# Each slot asks GitHub for a just-in-time configuration, which registers a
# runner for exactly one job with the pool label, starts that runner as USER
# in USER's login session -- where UI tests have a window server -- and waits
# for it to exit. A job that selects the pool label takes whichever slot is
# free; raising MACOS_RUNNER_SLOTS adds capacity.
#
# The credential stays outside the account. The supervisor runs as root with a
# token only root can read; GitHub fixes each runner's name, labels, and group,
# so the account only ever receives one runner's own configuration. Root runs,
# reads, and writes nothing the account controls. USER creates each slot's
# directory from the first runner's files, and the runner starts as a one-shot
# launchd job in USER's GUI domain, with the keys the first runner's own
# service uses, from a definition root writes in its own directory and deletes
# once launchd has it. The configuration reaches the runner in that job's
# environment (ACTIONS_RUNNER_INPUT_JITCONFIG), never as an argument: macOS
# shows every user's process arguments to every other user.
#
# A pool runner is single-use but its host is not: jobs share the account, its
# session, and the Mac, and a slot keeps its work directory between jobs, as
# the first runner does. So the runner group, checked before every
# registration, must admit only private repositories (see "macOS runner pool"
# in README.md).
#
# Configuration, from the environment (defaults in parentheses):
#   MACOS_RUNNER_ORG        organization (autumngarage)
#   MACOS_RUNNER_GROUP      runner group, restricted to the private consumers (macos)
#   MACOS_RUNNER_LABEL      the label pool jobs select (ci-studio-pool)
#   MACOS_RUNNER_SLOTS      pool jobs run at once, beside the first runner (2)
#   MACOS_RUNNER_USER       the CI account whose session runs the jobs (ci)
#   MACOS_RUNNER_STATE_DIR  root's directory for the token, the installed copy,
#                           and slot state (/Library/Application Support/$AGENT_ID)
#   MACOS_RUNNER_TOKEN_FILE the GitHub token, private to root (STATE_DIR/github-token);
#                           the kind linux-runner.sh uses: a fine-grained token with
#                           the organization permission "Self-hosted runners: read and write"
#
# Runs under macOS's /bin/bash 3.2: no associative arrays, mapfile, or wait -n.

set -euo pipefail

ORG="${MACOS_RUNNER_ORG:-autumngarage}"
GROUP="${MACOS_RUNNER_GROUP:-macos}"
LABEL="${MACOS_RUNNER_LABEL:-ci-studio-pool}"
SLOTS="${MACOS_RUNNER_SLOTS:-2}"
RUN_USER="${MACOS_RUNNER_USER:-ci}"
AGENT_ID="com.autumngarage.macos-pool-runner"
state_dir="${MACOS_RUNNER_STATE_DIR:-/Library/Application Support/$AGENT_ID}"
TOKEN_FILE="${MACOS_RUNNER_TOKEN_FILE:-$state_dir/github-token}"
DAEMON_DIR="${MACOS_RUNNER_DAEMON_DIR:-/Library/LaunchDaemons}"
LOG_FILE="${MACOS_RUNNER_LOG:-/Library/Logs/$AGENT_ID.log}"
# A test seam and a one-shot probe: stop each slot after this many jobs. Unset
# (the default) means forever.
MAX_JOBS="${MACOS_RUNNER_MAX_JOBS:-}"
# Seconds between checks on a slot's running job.
POLL=10
BACKOFF_START=15
BACKOFF_MAX=300

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# log, die, need, the token file, the runner-group check, and just-in-time
# registration, shared with runner/linux-runner.sh.
# shellcheck source=runner/jit.sh
. "$here/jit.sh"

case "$SLOTS" in '' | *[!0-9]* | 0) die "MACOS_RUNNER_SLOTS must be a positive integer, not '$SLOTS'" ;; esac
case "$MAX_JOBS" in *[!0-9]*) die "MACOS_RUNNER_MAX_JOBS must be a non-negative integer, not '$MAX_JOBS'" ;; esac
case "$RUN_USER" in '' | *[!A-Za-z0-9._-]*) die "MACOS_RUNNER_USER must be an account name, not '$RUN_USER'" ;; esac

require_root() {
  [ "$(id -u)" -eq 0 ] || die "$1 needs root; run it with sudo"
}

user_home() {
  dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true
}

# The account and the first runner, whose files every slot copies. Sets home,
# uid, and first.
resolve_user() {
  home="$(user_home "$RUN_USER")"
  [ -n "$home" ] && [ -d "$home" ] || die "no local user '$RUN_USER' with a home directory"
  uid="$(id -u "$RUN_USER")"
  first="$home/actions-runner"
  [ -f "$first/.runner" ] \
    || die "$first is not a configured runner; register $RUN_USER's first runner by hand, then start the pool"
}

slot_dir() { printf '%s/actions-runner-pool-%s' "$home" "$1"; }
slot_label() { printf '%s.slot-%s' "$AGENT_ID" "$1"; }

# The account's home is the account's to write, and so its jobs', so root
# does no file work there: a path a job replaced with a symlink would turn
# root's write into one anywhere on the host.
as_user() { sudo -u "$RUN_USER" -H "$@"; }

# A slot path that is a symlink is a job's doing, not this script's.
refuse_symlinked_slots() {
  local slot=1
  while [ "$slot" -le "$SLOTS" ]; do
    [ ! -L "$(slot_dir "$slot")" ] \
      || die "$(slot_dir "$slot") is a symlink; a slot is a directory $RUN_USER creates. Remove it and restart the pool"
    slot=$((slot + 1))
  done
}

# The slot's runner files, copied by the account from the first runner once:
# the runner's own files, not that runner's registration, credentials,
# service, work, or diagnostics. A single-use runner writes its own
# registration from its configuration, and updates itself in place when
# GitHub asks it to.
prepare_slot() {
  local dir
  dir="$(slot_dir "$1")"
  [ ! -x "$dir/run.sh" ] || return 0
  log "slot $1: copying the runner's files from $first to $dir as $RUN_USER"
  as_user mkdir -p "$dir" \
    && as_user rsync -a \
      --exclude '/.runner' --exclude '/.runner_migrated' \
      --exclude '/.credentials' --exclude '/.credentials_rsaparams' \
      --exclude '/.service' --exclude '/_work' --exclude '/_diag' \
      --exclude '/svc.sh' --exclude '/runsvc.sh' \
      "$first/" "$dir/"
}

# A logged-in account has a GUI domain; without one there is no window
# server for UI tests, and nothing to start a runner in.
session_up() { launchctl print "gui/$uid" >/dev/null 2>&1; }

# The slot's launchd job: running (or about to start), done, or absent. The
# job's own state is the first `state =` line launchctl prints.
slot_job() {
  local out
  out="$(launchctl print "gui/$uid/$(slot_label "$1")" 2>/dev/null)" || {
    echo absent
    return 0
  }
  printf '%s\n' "$out" | awk '
    /^[[:space:]]*state = / && state == "" { state = $0 }
    /last exit code = \(never exited\)/ { never = 1 }
    END { print (state ~ /= running/ || never) ? "running" : "done" }'
}

# The exit code of the slot's finished job, or nothing if launchd has none.
exit_code() {
  local out
  out="$(launchctl print "gui/$uid/$(slot_label "$1")" 2>/dev/null)" || return 0
  printf '%s\n' "$out" | awk -F' = ' '/^[[:space:]]*last exit code = / && !done { split($2, a, ":"); print a[1]; done = 1 }'
}

wait_for_job() {
  while [ "$(slot_job "$1")" = running ]; do sleep "$POLL"; done
}

# The job definition, private to root. KeepAlive is absent: the runner exits
# after its one job, and the supervisor starts the next. The runner reads the
# slot's .env itself but takes its jobs' PATH from its own environment, so the
# job exports the slot's .path first, as the first runner's service wrapper
# (runsvc.sh) does -- in the job, as USER, so root never reads the file.
write_job() { # plist label dir config
  (
    umask 077
    cat >"$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$2</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>if [ -f .path ]; then PATH="\$(cat .path)"; export PATH; fi; exec ./run.sh</string>
  </array>
  <key>WorkingDirectory</key><string>$3</string>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>SessionCreate</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ACTIONS_RUNNER_INPUT_JITCONFIG</key><string>$4</string>
  </dict>
</dict>
</plist>
EOF
  )
}

run_slot() {
  local slot="$1" backoff="$BACKOFF_START" jobs=0
  local label plist gid name response jit id started rc
  label="$(slot_label "$slot")"
  plist="$state_dir/slot-$slot.plist"
  while :; do
    if [ -n "$MAX_JOBS" ] && [ "$jobs" -ge "$MAX_JOBS" ]; then
      return 0
    fi
    # A runner a previous supervisor started finishes its job first.
    wait_for_job "$slot"
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    if ! session_up; then
      log "slot $slot: $RUN_USER is not logged in; registering nothing, retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    if ! prepare_slot "$slot"; then
      log "slot $slot: $RUN_USER could not copy the runner's files; retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    # Before every registration, not once at start: the group is the
    # boundary, and it can be edited while the supervisor runs.
    if ! gid="$(group_id)"; then
      log "slot $slot: runner group '$GROUP' failed its check; registering nothing, retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    name="$LABEL-$slot-$(date +%s)"
    if ! response="$(request_jit "$name" "$gid")"; then
      log "slot $slot: could not register a runner ($response); retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    jit="$(printf '%s' "$response" | jq -r '.encoded_jit_config // empty' 2>/dev/null || true)"
    id="$(printf '%s' "$response" | jq -r '.runner.id // empty' 2>/dev/null || true)"
    # The configuration is base64 and goes into a plist as text; anything
    # else is not a configuration.
    case "$jit" in '' | *[!A-Za-z0-9+/=]*) jit="" ;; esac
    if [ -z "$jit" ] || [ -z "$id" ]; then
      forget_runner "$id"
      log "slot $slot: GitHub returned no runner configuration; retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    printf '%s %s\n' "$id" "$name" >"$state_dir/slot-$slot"
    write_job "$plist" "$label" "$(slot_dir "$slot")" "$jit"
    started="$(date +%s)"
    rc=0
    launchctl bootstrap "gui/$uid" "$plist" || rc=$?
    # launchd holds the definition now; the configuration is not left on disk.
    rm -f "$plist"
    if [ "$rc" -ne 0 ]; then
      forget_runner "$id"
      rm -f "$state_dir/slot-$slot"
      log "slot $slot: launchd would not start runner $name ($rc); retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    log "slot $slot: runner $name ($id) is waiting for a job"
    wait_for_job "$slot"
    rc="$(exit_code "$slot")"
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    forget_runner "$id"
    rm -f "$state_dir/slot-$slot"
    jobs=$((jobs + 1))
    log "slot $slot: runner $name exited (${rc:-unknown}) after $(($(date +%s) - started))s"
    # A runner that dies at once (a broken slot, a runner that cannot start)
    # would otherwise register and discard runners in a tight loop.
    if [ "${rc:-1}" != 0 ] && [ $(($(date +%s) - started)) -lt 30 ]; then
      log "slot $slot: the runner failed immediately; retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
    else
      backoff="$BACKOFF_START"
    fi
  done
}

# On stop, take down the pool's runners and the registrations they hold, so
# nothing is left waiting for work.
stop_slots() {
  local file id name slot
  trap - INT TERM
  for file in "$state_dir"/slot-*; do
    [ -f "$file" ] || continue
    slot="${file##*/slot-}"
    case "$slot" in *[!0-9]*) continue ;; esac
    read -r id name <"$file" || true
    launchctl bootout "gui/$uid/$(slot_label "$slot")" >/dev/null 2>&1 || true
    forget_runner "$id"
    rm -f "$file"
  done
  kill 0 2>/dev/null || true
}

cmd_run() {
  local gid slot
  require_root "run"
  need launchctl "the pool needs macOS launchd"
  need rsync "install rsync"
  need gh "install the GitHub CLI"
  need jq "install jq"
  load_token
  resolve_user
  refuse_symlinked_slots
  session_up || die "$RUN_USER is not logged in; the pool's runners start in $RUN_USER's login session"
  gid="$(group_id)"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  trap stop_slots INT TERM
  log "supervising $SLOTS slot(s) for label $LABEL in $ORG runner group $GROUP ($gid) as $RUN_USER"
  slot=1
  while [ "$slot" -le "$SLOTS" ]; do
    run_slot "$slot" &
    slot=$((slot + 1))
  done
  wait
}

daemon_plist_path() { printf '%s/%s.plist\n' "$DAEMON_DIR" "$AGENT_ID"; }

# The pool at boot: a LaunchDaemon runs an installed copy of this script as
# root, which waits for USER's login session (auto-login brings it back after
# a restart). The token must already be in place, private to root.
cmd_install_daemon() {
  local plist
  require_root "install-daemon"
  need launchctl "install-daemon needs macOS launchd"
  resolve_user
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  [ -f "$TOKEN_FILE" ] \
    || die "no token at $TOKEN_FILE; put one that can manage the organization's self-hosted runners there, private to root: sudo install -m 600 -o root <token file> '$TOKEN_FILE'"
  [ "$(file_owner "$TOKEN_FILE")" = "$(id -un)" ] || die "$TOKEN_FILE must belong to root"
  case "$(file_mode "$TOKEN_FILE")" in
    600 | 400) ;;
    *) die "$TOKEN_FILE must be private to root: chmod 600 it" ;;
  esac
  # The token and the group, checked now rather than in the daemon's log.
  load_token
  group_id >/dev/null
  # A copy, so a checkout that later switches branches cannot change what runs.
  cp "$here/macos-runner.sh" "$here/jit.sh" "$state_dir/"
  plist="$(daemon_plist_path)"
  mkdir -p "$DAEMON_DIR" "$(dirname "$LOG_FILE")"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$state_dir/macos-runner.sh</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>MACOS_RUNNER_ORG</key><string>$ORG</string>
    <key>MACOS_RUNNER_GROUP</key><string>$GROUP</string>
    <key>MACOS_RUNNER_LABEL</key><string>$LABEL</string>
    <key>MACOS_RUNNER_SLOTS</key><string>$SLOTS</string>
    <key>MACOS_RUNNER_USER</key><string>$RUN_USER</string>
    <key>MACOS_RUNNER_STATE_DIR</key><string>$state_dir</string>
    <key>MACOS_RUNNER_TOKEN_FILE</key><string>$TOKEN_FILE</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>
EOF
  chown root:wheel "$plist"
  chmod 644 "$plist"
  launchctl bootout "system/$AGENT_ID" >/dev/null 2>&1 || true
  launchctl bootstrap system "$plist" \
    || die "launchctl could not load $plist"
  log "installed $AGENT_ID: $SLOTS slot(s) for $RUN_USER; logs in $LOG_FILE"
}

cmd_uninstall_daemon() {
  require_root "uninstall-daemon"
  need launchctl "uninstall-daemon needs macOS launchd"
  # The daemon's stop takes down its runners and their registrations.
  launchctl bootout "system/$AGENT_ID" >/dev/null 2>&1 || true
  rm -f "$(daemon_plist_path)"
  log "removed $AGENT_ID from $DAEMON_DIR"
}

cmd_status() {
  local slot
  require_root "status"
  launchctl print "system/$AGENT_ID" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) =' \
    || echo "the daemon $AGENT_ID is not loaded"
  resolve_user
  slot=1
  while [ "$slot" -le "$SLOTS" ]; do
    echo "slot $slot: $(slot_job "$slot")"
    slot=$((slot + 1))
  done
  load_token
  gh api --paginate "orgs/$ORG/actions/runners" \
    --jq ".runners[] | select(any(.labels[]; .name == \"$LABEL\")) | \"\(.name)  \(.status)  busy=\(.busy)\""
}

case "${1:-}" in
  run) cmd_run ;;
  install-daemon) cmd_install_daemon ;;
  uninstall-daemon) cmd_uninstall_daemon ;;
  status) cmd_status ;;
  *)
    sed -n '3,/^# Runs under macOS/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
