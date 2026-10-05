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
#   MACOS_RUNNER_RESTART_AFTER
#                           seconds USER may be without a login session before the
#                           supervisor restarts the Mac (0, the default: never); see
#                           "A lost session" below
#
# A lost session. The runners need USER's login session, and macOS ends every
# session when its window server dies: on 2026-09-30 a watchdog killed
# WindowServer, auto-login only happens at boot, and the pool and the first
# runner were down for nine hours until a person logged USER in -- which then
# left the session half-working, because USER's per-user daemons were the old
# session's. Only a restart brings back a clean session by itself. A session
# can also outlive its window server: on 2026-10-05 the watchdog killed
# WindowServer again, the owner's session ended, and USER's loginwindow kept
# running, cut off from the new window server -- still "logged in" to launchd,
# while every app test hung and nobody could log USER in until a restart
# (AUT-2255). That is a lost session too. So with
# MACOS_RUNNER_RESTART_AFTER set, the supervisor restarts the Mac once USER has
# had no usable session for that long, and only when a restart is both safe and
# useful: nobody is at the console (its owner reads as root, the login window;
# an owner that cannot be read holds the restart),
# auto-login is configured for USER, and it has restarted fewer than
# RESTART_LIMIT times in the last day, so a Mac whose auto-login is broken is
# left for a person instead of restarting forever.
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
# Seconds a leftover process gets to exit on SIGTERM before SIGKILL.
REAP_GRACE=5
# A test seam: what signals leftovers (default: the shell's kill).
KILL_CMD="${MACOS_RUNNER_KILL_CMD:-kill}"
RESTART_AFTER="${MACOS_RUNNER_RESTART_AFTER:-0}"
# Automatic restarts allowed in any 24 hours.
RESTART_LIMIT=2
# Test seams: what restarts the Mac, and what reports the console's owner, the
# boot time in epoch seconds, the auto-login account, and (exit 0) a login
# session older than the window server.
RESTART_CMD="${MACOS_RUNNER_RESTART_CMD:-shutdown -r now}"
CONSOLE_USER_CMD="${MACOS_RUNNER_CONSOLE_USER_CMD:-stat -f %Su /dev/console}"
BOOT_TIME_CMD="${MACOS_RUNNER_BOOT_TIME_CMD:-}"
AUTOLOGIN_CMD="${MACOS_RUNNER_AUTOLOGIN_CMD:-defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser}"
SESSION_STALE_CMD="${MACOS_RUNNER_SESSION_STALE_CMD:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# log, die, need, the token file, the runner-group check, and just-in-time
# registration, shared with runner/linux-runner.sh.
# shellcheck source=runner/jit.sh
. "$here/jit.sh"

case "$SLOTS" in '' | *[!0-9]* | 0) die "MACOS_RUNNER_SLOTS must be a positive integer, not '$SLOTS'" ;; esac
case "$MAX_JOBS" in *[!0-9]*) die "MACOS_RUNNER_MAX_JOBS must be a non-negative integer, not '$MAX_JOBS'" ;; esac
case "$RUN_USER" in '' | *[!A-Za-z0-9._-]*) die "MACOS_RUNNER_USER must be an account name, not '$RUN_USER'" ;; esac
case "$RESTART_AFTER" in '' | *[!0-9]*) die "MACOS_RUNNER_RESTART_AFTER must be a number of seconds, not '$RESTART_AFTER'" ;; esac

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

# When a process started, in epoch seconds; nothing when it is gone.
started_at() {
  local at
  at="$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/ *$//' || true)"
  [ -n "$at" ] || return 0
  LC_ALL=C date -j -f '%a %b %d %T %Y' "$at" +%s 2>/dev/null || true
}

# USER's login window started before the running window server, so the
# session belongs to a window server that is gone. At boot the two start in
# the same second, which is not stale. Anything that cannot be read is not
# stale either: a probe that fails must never be what restarts the Mac.
session_stale() {
  local lw ws lw_at ws_at
  if [ -n "$SESSION_STALE_CMD" ]; then
    $SESSION_STALE_CMD
    return
  fi
  lw="$(pgrep -u "$uid" -x loginwindow 2>/dev/null | head -1 || true)"
  ws="$(pgrep -x WindowServer 2>/dev/null | head -1 || true)"
  [ -n "$lw" ] && [ -n "$ws" ] || return 1
  lw_at="$(started_at "$lw")"
  ws_at="$(started_at "$ws")"
  case "$lw_at" in '' | *[!0-9]*) return 1 ;; esac
  case "$ws_at" in '' | *[!0-9]*) return 1 ;; esac
  [ "$lw_at" -lt "$ws_at" ]
}

# A logged-in account has a GUI domain; without one there is no window
# server for UI tests, and nothing to start a runner in. A domain whose login
# window predates the window server has none either. session_gap says which,
# for the log.
session_gap=""
session_up() {
  if ! launchctl print "gui/$uid" >/dev/null 2>&1; then
    session_gap="is not logged in"
    return 1
  fi
  if session_stale; then
    session_gap="has a login session older than the window server, which cannot reach the display"
    return 1
  fi
  session_gap=""
}

console_user() { $CONSOLE_USER_CMD 2>/dev/null || true; }
autologin_user() { $AUTOLOGIN_CMD 2>/dev/null || true; }
boot_time() {
  if [ -n "$BOOT_TIME_CMD" ]; then
    $BOOT_TIME_CMD 2>/dev/null || true
  else
    sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p'
  fi
}

# Why a lost session is not being restarted, logged once per reason rather
# than on every look.
hold_restart() {
  [ "$(cat "$state_dir/session-lost-reason" 2>/dev/null || true)" = "$1" ] && return 0
  printf '%s\n' "$1" >"$state_dir/session-lost-reason"
  log "$RUN_USER ${session_gap:-has no usable login session}; not restarting the Mac: $1"
}

# USER has no usable login session. Remember since when, and restart the Mac once
# that has lasted RESTART_AFTER seconds and a restart is safe and useful (see
# "A lost session" above). The invariant: never restart under a person, never
# when auto-login would not bring USER back, never more than RESTART_LIMIT
# times a day.
session_lost() {
  local now since boot lost auto owner recent stamp
  [ "$RESTART_AFTER" -gt 0 ] || return 0
  now="$(date +%s)"
  since="$(cat "$state_dir/session-lost-since" 2>/dev/null || true)"
  case "$since" in '' | *[!0-9]*) since="$now" ;; esac
  # A mark from before this boot says nothing about this boot's session: at
  # boot the daemon starts before auto-login has finished.
  boot="$(boot_time)"
  case "$boot" in '' | *[!0-9]*) boot=0 ;; esac
  [ "$since" -ge "$boot" ] || since="$boot"
  printf '%s\n' "$since" >"$state_dir/session-lost-since"
  lost=$((now - since))
  [ "$lost" -ge "$RESTART_AFTER" ] || return 0
  auto="$(autologin_user)"
  if [ "$auto" != "$RUN_USER" ]; then
    hold_restart "auto-login is '${auto:-off}', not $RUN_USER, so a restart would not bring the session back"
    return 0
  fi
  # Only the login window authorizes a restart. An owner that cannot be read
  # is not proof that nobody is there.
  owner="$(console_user)"
  case "$owner" in
    root) ;;
    '')
      hold_restart "the console's owner could not be read"
      return 0
      ;;
    *)
      hold_restart "$owner is at the console"
      return 0
      ;;
  esac
  recent=0
  if [ -f "$state_dir/restarts" ]; then
    while read -r stamp; do
      case "$stamp" in '' | *[!0-9]*) continue ;; esac
      [ $((now - stamp)) -ge 86400 ] || recent=$((recent + 1))
    done <"$state_dir/restarts"
  fi
  if [ "$recent" -ge "$RESTART_LIMIT" ]; then
    hold_restart "it has already restarted $recent times in the last 24 hours; $RUN_USER's auto-login needs a person"
    return 0
  fi
  printf '%s\n' "$now" >>"$state_dir/restarts"
  rm -f "$state_dir/session-lost-since" "$state_dir/session-lost-reason"
  log "$RUN_USER ${session_gap:-has no usable login session}, for ${lost}s now, and nobody is at the console; restarting the Mac so auto-login restores it"
  $RESTART_CMD || log "the restart command failed: $RESTART_CMD"
}

session_back() { rm -f "$state_dir/session-lost-since" "$state_dir/session-lost-reason"; }

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

# What a slot's job left running is ended before the slot's next job. A test
# that moves its children into a session of their own escapes the process
# group launchd ends with the job, and the runner's own cleanup misses them
# too (actions/runner#4601); every job shares the account, so leftovers pile
# up, and one holding a pipe or a lock is the shape of the hangs AUT-2058
# fixed (AUT-2076).
#
# A command line naming this slot's work directory is a candidate, not a
# verdict: every runner shares the account, so another slot's running job --
# or ci-studio's -- could name this path in its arguments. What makes a
# process a leftover is provenance: a running job's processes all descend
# from its live runner, while a leftover of this slot's ended job has none
# above it (this slot's runner has exited by now). So a candidate is ended
# only when no live runner process of any slot is among its ancestors. The
# trailing slash keeps pool-1 from matching pool-10.
live_runner_pids() {
  pgrep -U "$uid" -f '/actions-runner[^/]*/(bin/Runner\.(Listener|Worker)|bin/RunnerService\.js|run\.sh|run-helper\.sh|runsvc\.sh)' 2>/dev/null | tr '\n' ' ' || true
}
# under_live_runner PID ROOTS: whether PID or an ancestor is one of ROOTS.
under_live_runner() {
  local p="$1" roots="$2" hops=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$hops" -lt 64 ]; do
    case " $roots " in *" $p "*) return 0 ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    hops=$((hops + 1))
  done
  return 1
}
leftovers() { # slot
  local work roots pid out=""
  work="$(slot_dir "$1")/_work/"
  roots="$(live_runner_pids)"
  for pid in $(pgrep -U "$uid" -f "$work" 2>/dev/null || true); do
    under_live_runner "$pid" "$roots" || out="$out $pid"
  done
  printf '%s' "${out# }"
}
reap_slot() {
  local pids
  pids="$(leftovers "$1")"
  [ -n "$pids" ] || return 0
  log "slot $1: ending $(printf '%s' "$pids" | wc -w | tr -d ' ') process(es) its last job left running: $pids"
  # shellcheck disable=SC2086 # one argument per pid
  "$KILL_CMD" -TERM $pids 2>/dev/null || true
  sleep "$REAP_GRACE"
  pids="$(leftovers "$1")"
  [ -n "$pids" ] || return 0
  log "slot $1: killing $pids, which ignored SIGTERM"
  # shellcheck disable=SC2086 # one argument per pid
  "$KILL_CMD" -KILL $pids 2>/dev/null || true
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
    reap_slot "$slot"
    if ! session_up; then
      # One slot speaks for the pool: two slots reading the mark at the same
      # moment would otherwise each restart and each count against the limit.
      [ "$slot" -ne 1 ] || session_lost
      log "slot $slot: $RUN_USER $session_gap; registering nothing, retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    # The session is here: a loss that ended before the limit leaves no mark
    # for the next loss to inherit.
    [ "$slot" -ne 1 ] || session_back
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
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  # launchd starts this again a minute after it exits, so a session that
  # stays lost is looked at once a minute until it returns or the Mac restarts.
  if ! session_up; then
    session_lost
    die "$RUN_USER $session_gap; the pool's runners start in $RUN_USER's login session"
  fi
  session_back
  gid="$(group_id)"
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
  # A restart only restores the session when auto-login is USER's.
  if [ "$RESTART_AFTER" -gt 0 ] && [ "$(autologin_user)" != "$RUN_USER" ]; then
    die "MACOS_RUNNER_RESTART_AFTER needs auto-login set to $RUN_USER (it is '$(autologin_user)'): a restart would not bring $RUN_USER's session back"
  fi
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
    <key>MACOS_RUNNER_RESTART_AFTER</key><string>$RESTART_AFTER</string>
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
  if [ "$RESTART_AFTER" -gt 0 ]; then
    log "installed $AGENT_ID: $SLOTS slot(s) for $RUN_USER, restarting the Mac after ${RESTART_AFTER}s without $RUN_USER's session; logs in $LOG_FILE"
  else
    log "installed $AGENT_ID: $SLOTS slot(s) for $RUN_USER; logs in $LOG_FILE"
  fi
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
  if [ "$RESTART_AFTER" -gt 0 ]; then
    echo "restart: after ${RESTART_AFTER}s without $RUN_USER's session (auto-login: $(autologin_user); console: $(console_user); restarts recorded: $(grep -c . "$state_dir/restarts" 2>/dev/null || echo 0))"
  else
    echo "restart: never (MACOS_RUNNER_RESTART_AFTER is 0)"
  fi
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
