#!/usr/bin/env bash
# runner/macos-runner.sh (AUT-2013): pool slots in the CI account's login
# session, each a single-use runner. The CI account's jobs control its home,
# so this pins the boundary: the org credential never reaches the account,
# root does no file work in its home, and the runner's configuration reaches
# it through a root-private launchd definition, never a process argument.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/runner/macos-runner.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "  OK: $*"; }

CONFIG="U0lOR0xFLVVTRS1DT05GSUc="
POOL_LABEL=com.autumngarage.macos-pool-runner.slot
real_user="$(id -un)"
real_group="$(id -gn)"

bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >>"\$FAKE_CALLS"
[ -n "\${GH_TOKEN:-}" ] && printf 'gh-token %s\n' "\$GH_TOKEN" >>"\$FAKE_CALLS"
once() { [ -f "\$FAKE_STATE/\$1" ] && [ ! -f "\$FAKE_STATE/\$1.done" ] && touch "\$FAKE_STATE/\$1.done"; }
case "\$*" in
  *runner-groups/*/repositories*)
    [ -f "\$FAKE_STATE/empty-group" ] && exit 0
    echo "autumngarage/nyx true"
    [ -f "\$FAKE_STATE/public-repo" ] && echo "autumngarage/touchstone false"
    exit 0
    ;;
  *actions/runner-groups*)
    [ -f "\$FAKE_STATE/no-group" ] && exit 0
    visibility=selected
    [ -f "\$FAKE_STATE/broad-group" ] && visibility=all
    public=false
    [ -f "\$FAKE_STATE/public-allowed" ] && public=true
    echo "{\"id\":5,\"visibility\":\"\$visibility\",\"allows_public_repositories\":\$public}"
    exit 0
    ;;
  *generate-jitconfig*)
    if once jit-fails; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
    if once jit-garbage; then echo '{"runner":{"id":4141},"encoded_jit_config":"not a <config>"}'; exit 0; fi
    echo '{"runner":{"id":4242},"encoded_jit_config":"$CONFIG"}'
    ;;
  # GitHub has already removed a single-use runner that took its job.
  *"-X DELETE"*) exit 1 ;;
esac
EOF
# launchctl: the account's GUI domain and the slots' one-shot jobs. A job
# reports running for FAKE_RUNNING_POLLS prints, then its exit code.
cat >"$bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$FAKE_CALLS"
job() { printf '%s/job-%s' "$FAKE_STATE" "${1##*/}"; }
case "$1" in
  print)
    case "$2" in
      gui/*/*)
        f="$(job "$2")"
        [ -f "$f" ] || exit 113
        n="$(cat "$f")"
        if [ "$n" -gt 0 ]; then
          echo $((n - 1)) >"$f"
          printf '\tstate = running\n\tpid = 99\n\tlast exit code = (never exited)\n\tendpoints = {\n\t\tstate = active\n\t}\n'
        else
          printf '\tstate = not running\n\tlast exit code = %s: EX_CONFIG\n\tendpoints = {\n\t\tstate = active\n\t}\n' "$(cat "$f.rc")"
        fi
        ;;
      gui/*)
        [ ! -f "$FAKE_STATE/no-session" ] || exit 113
        if [ -f "$FAKE_STATE/session-drops" ]; then
          # Up when the supervisor starts, down at the slot's first look.
          count="$(cat "$FAKE_STATE/session-count" 2>/dev/null || echo 0)"
          echo $((count + 1)) >"$FAKE_STATE/session-count"
          [ "$count" -ne 1 ] || exit 113
        fi
        ;;
      system/*)
        # daemon-stays: the daemon being replaced never leaves.
        [ ! -f "$FAKE_STATE/daemon-stays" ] || exit 0
        # daemon-lingers: the daemon being replaced is still there for the
        # first two looks after its bootout.
        [ -f "$FAKE_STATE/daemon-lingers" ] || exit 113
        count="$(cat "$FAKE_STATE/linger-count" 2>/dev/null || echo 0)"
        echo $((count + 1)) >"$FAKE_STATE/linger-count"
        [ "$count" -lt 2 ] || exit 113
        ;;
      *) exit 113 ;;
    esac
    ;;
  bootstrap)
    if [ "$2" = system ]; then
      # daemon-busy: launchd refuses the first two loads, as it does while
      # the old daemon is still exiting. daemon-stuck: it refuses them all,
      # as it does (daemon-stays) over a service that is still loaded.
      if [ -f "$FAKE_STATE/daemon-stuck" ] || [ -f "$FAKE_STATE/daemon-stays" ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
      if [ -f "$FAKE_STATE/daemon-busy" ]; then
        count="$(cat "$FAKE_STATE/busy-count" 2>/dev/null || echo 0)"
        echo $((count + 1)) >"$FAKE_STATE/busy-count"
        if [ "$count" -lt 2 ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
      fi
      exit 0
    fi
    [ ! -f "$FAKE_STATE/bootstrap-fails" ] || [ -f "$FAKE_STATE/bootstrap-fails.done" ] || {
      touch "$FAKE_STATE/bootstrap-fails.done"
      exit 5
    }
    label="$(sed -n 's:.*<key>Label</key><string>\(.*\)</string>.*:\1:p' "$3")"
    cp "$3" "$FAKE_STATE/bootstrapped-$label.plist"
    # Every configuration a job was given, kept apart from the call log, which
    # records process arguments.
    sed -n 's:.*<key>ACTIONS_RUNNER_INPUT_JITCONFIG</key><string>\(.*\)</string>.*:\1:p' "$3" >>"$FAKE_STATE/configs"
    printf 'plist-mode %s\n' "$(stat -c %a "$3" 2>/dev/null || stat -f %Lp "$3")" >>"$FAKE_CALLS"
    echo "${FAKE_RUNNING_POLLS:-1}" >"$(job "$label")"
    echo "${FAKE_JOB_RC:-0}" >"$(job "$label").rc"
    ;;
  bootout)
    f="$(job "$2")"
    rm -f "$f" "$f.rc"
    ;;
esac
EOF
# sudo -u USER -H CMD...: records the user and the command, and runs it here.
cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -u ] || exit 1
user="$2"
shift 2
[ "$1" != -H ] || shift
printf 'as %s %s\n' "$user" "$*" >>"$FAKE_CALLS"
exec "$@"
EOF
# id: root unless the not-root flag is set; the account's uid is 502; the
# installing user's name is the real one, so stat's owner check agrees.
cat >"$bin/id" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -u)
    if [ -n "\${2:-}" ]; then echo 502
    elif [ -f "\$FAKE_STATE/not-root" ]; then echo 501
    else echo 0; fi
    ;;
  -un) echo "$real_user" ;;
  -gn) echo "$real_group" ;;
esac
EOF
cat >"$bin/dscl" <<'EOF'
#!/usr/bin/env bash
[ -f "$FAKE_STATE/no-user" ] && exit 56
echo "NFSHomeDirectory: $FAKE_HOME"
EOF
cat >"$bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$FAKE_CALLS"
EOF
cat >"$bin/chown" <<'EOF'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >>"$FAKE_CALLS"
EOF
# pgrep: the processes a slot's job left behind. With the leftover flag set,
# pool slot 1 has two; one survives SIGTERM when the resist flag is set too.
cat >"$bin/pgrep" <<'EOF'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >>"$FAKE_CALLS"
case "$*" in
  *"Runner"*"Listener"*)
    # The live runners: another slot's listener, when one is running.
    [ -f "$FAKE_STATE/foreign" ] && echo 7001
    exit 0
    ;;
  *"/actions-runner-pool-1/_work/")
    [ -f "$FAKE_STATE/leftover" ] || exit 1
    if [ -f "$FAKE_STATE/termed" ]; then
      [ -f "$FAKE_STATE/resist" ] || exit 1
      echo 4102
    else
      printf '4101\n4102\n'
      # A running job on another slot whose arguments name this slot's path.
      [ -f "$FAKE_STATE/foreign" ] && echo 4103
    fi
    ;;
  *) exit 1 ;;
esac
EOF
# ps -o ppid= -p PID: 4101 and 4102 are orphans; 4103 runs under the live
# listener 7001 (through its worker 7002).
cat >"$bin/ps" <<'EOF'
#!/usr/bin/env bash
pid="${!#}"
case "$pid" in
  4101 | 4102 | 7001) echo 1 ;;
  4103) echo 7002 ;;
  7002) echo 7001 ;;
  *) echo 1 ;;
esac
EOF
cat >"$bin/fake-kill" <<'EOF'
#!/usr/bin/env bash
printf 'kill %s\n' "$*" >>"$FAKE_CALLS"
[ "$1" != -TERM ] || touch "$FAKE_STATE/termed"
EOF
# The lost-session probes and the restart itself: the console's owner (root
# is the login window), the boot time, the auto-login account, and a restart
# that only records that it was asked for.
cat >"$bin/fake-console" <<'EOF'
#!/usr/bin/env bash
[ ! -f "$FAKE_STATE/console-fails" ] || exit 1
cat "$FAKE_STATE/console" 2>/dev/null || echo root
EOF
cat >"$bin/fake-boot" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_STATE/boot" 2>/dev/null || echo 0
EOF
cat >"$bin/fake-autologin" <<'EOF'
#!/usr/bin/env bash
[ ! -f "$FAKE_STATE/no-autologin" ] || exit 1
cat "$FAKE_STATE/autologin" 2>/dev/null || echo ci
EOF
cat >"$bin/fake-restart" <<'EOF'
#!/usr/bin/env bash
printf 'restart %s\n' "$*" >>"$FAKE_CALLS"
EOF
# A login session older than the window server: exit 0 says so.
cat >"$bin/fake-stale" <<'EOF'
#!/usr/bin/env bash
# stale-while-running: fresh when the supervisor starts and when the slot
# registers its runner, stale from the third look on, which is the slot
# waiting on its job.
if [ -f "$FAKE_STATE/stale-while-running" ]; then
  count="$(cat "$FAKE_STATE/stale-count" 2>/dev/null || echo 0)"
  echo $((count + 1)) >"$FAKE_STATE/stale-count"
  [ "$count" -ge 2 ]
  exit
fi
[ -f "$FAKE_STATE/stale-session" ]
EOF
chmod +x "$bin"/*

home="$tmp/home"
first="$home/actions-runner"
# The account's first runner: its files beside its own identity and state.
seed_home() {
  rm -rf "${home:?}"
  mkdir -p "$first/bin" "$first/_work/job" "$first/_diag"
  echo '{"agentName":"ci-studio"}' >"$first/.runner"
  echo '{}' >"$first/.runner_migrated"
  echo secret >"$first/.credentials"
  echo secret >"$first/.credentials_rsaparams"
  echo marker >"$first/.service"
  echo '/opt/homebrew/bin:/usr/bin:/bin' >"$first/.path"
  echo 'LANG=en_US.UTF-8' >"$first/.env"
  echo listener >"$first/bin/Runner.Listener"
  printf '#!/bin/bash\n' >"$first/run.sh"
  chmod +x "$first/run.sh"
  echo slot1-svc >"$first/svc.sh"
  echo slot1-runsvc >"$first/runsvc.sh"
}
seed_home
mkdir -p "$tmp/tok"
printf 'ghp_POOL\n' >"$tmp/tok/token"
chmod 600 "$tmp/tok/token"

# runner ARGS...: run the script against the fakes with a fresh call log and
# state; stdout+stderr land in $tmp/out and the exit code in $rc. BEFORE names
# a function to run once the fake state exists.
runner() {
  rm -rf "${tmp:?}/state" "${tmp:?}/fake" "${tmp:?}/daemons"
  mkdir -p "$tmp/state" "$tmp/fake"
  : >"$tmp/calls"
  for flag in ${FLAGS:-}; do touch "$tmp/fake/$flag"; done
  [ -z "${BEFORE:-}" ] || "$BEFORE"
  set +e
  env -u GH_TOKEN PATH="$bin:$PATH" FAKE_CALLS="$tmp/calls" FAKE_STATE="$tmp/fake" FAKE_HOME="$home" \
    FAKE_RUNNING_POLLS="${POLLS:-1}" FAKE_JOB_RC="${JOB_RC:-0}" \
    MACOS_RUNNER_STATE_DIR="$tmp/state" MACOS_RUNNER_TOKEN_FILE="${TOKEN_FILE:-$tmp/tok/token}" \
    MACOS_RUNNER_SLOTS="${SLOTS:-1}" MACOS_RUNNER_MAX_JOBS="${JOBS:-1}" \
    MACOS_RUNNER_DAEMON_DIR="$tmp/daemons" MACOS_RUNNER_LOG="$tmp/logs/pool.log" \
    MACOS_RUNNER_KILL_CMD="$bin/fake-kill" \
    MACOS_RUNNER_RESTART_AFTER="${RESTART_AFTER:-}" MACOS_RUNNER_RESTART_CMD="$bin/fake-restart now" \
    MACOS_RUNNER_CONSOLE_USER_CMD="$bin/fake-console" MACOS_RUNNER_BOOT_TIME_CMD="$bin/fake-boot" \
    MACOS_RUNNER_AUTOLOGIN_CMD="$bin/fake-autologin" \
    MACOS_RUNNER_SESSION_STALE_CMD="$bin/fake-stale" \
    bash "$script" "$@" >"$tmp/out" 2>&1
  rc=$?
  set -e
}
has() { grep -Fq -- "$1" "$tmp/calls" || fail "$2: expected '$1' in: $(cat "$tmp/calls")"; }
lacks() { ! grep -Eq -- "$1" "$tmp/calls" || fail "$2: unexpected '$1' in: $(cat "$tmp/calls")"; }
# refused TEXT LABEL: the last run failed and said TEXT.
refused() {
  if [ "$rc" -eq 0 ] || ! grep -Fq -- "$1" "$tmp/out"; then
    fail "$2 was not refused (exit $rc): $(cat "$tmp/out")"
  fi
}
line_of() { grep -nF -- "$1" "$tmp/calls" | head -1 | cut -d: -f1; }

echo "==> one job: a single-use runner in the account's session, holding only its configuration"
runner run
[ "$rc" -eq 0 ] || fail "a clean one-job run exited $rc: $(cat "$tmp/out")"
has 'gh-token ghp_POOL' "gh runs with root's token"
has 'runner_group_id=5' "registration binds the checked runner group"
has 'labels[]=self-hosted' "registration carries the self-hosted label every selector requires"
has 'labels[]=ci-studio-pool' "registration carries the pool label"
has 'name=ci-studio-pool-1-' "the runner is named for its slot"
slot="$home/actions-runner-pool-1"
has "as ci mkdir -p $slot" "the account creates its slot"
grep -q "^as ci rsync -a .* $first/ $slot/$" "$tmp/calls" || fail "the account did not copy the runner's files: $(cat "$tmp/calls")"
for kept in bin/Runner.Listener run.sh .path .env; do
  [ -e "$slot/$kept" ] || fail "the slot lacks the runner's $kept"
done
for private in .runner .runner_migrated .credentials .credentials_rsaparams .service _work _diag svc.sh runsvc.sh; do
  [ ! -e "$slot/$private" ] || fail "the slot copied the first runner's $private"
done
ok "the account copies the runner's files into its slot, and none of the first runner's identity or state"
job="$tmp/fake/bootstrapped-$POOL_LABEL-1.plist"
has "launchctl bootstrap gui/502 $tmp/state/slot-1.plist" "the runner starts in the account's GUI domain"
[ -f "$job" ] || fail "no job was bootstrapped"
# The runner takes its jobs' PATH from its own environment, as the first
# runner's service wrapper sets it from .path.
# shellcheck disable=SC2016
for want in "<key>Label</key><string>$POOL_LABEL-1</string>" \
  '<string>if [ -f .path ]; then PATH="$(cat .path)"; export PATH; fi; exec ./run.sh</string>' \
  "<key>WorkingDirectory</key><string>$slot</string>" '<key>ProcessType</key><string>Interactive</string>' \
  '<key>SessionCreate</key><true/>' "<key>ACTIONS_RUNNER_INPUT_JITCONFIG</key><string>$CONFIG</string>"; do
  grep -Fq -- "$want" "$job" || fail "the job lacks '$want': $(cat "$job")"
done
grep -q KeepAlive "$job" && fail "a single-use runner's job must not be kept alive"
sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$job" | grep -Fq "$CONFIG" \
  && fail "the configuration is in the job's arguments"
has 'plist-mode 600' "the job definition is private to root"
[ ! -e "$tmp/state/slot-1.plist" ] || fail "the job definition, which holds the configuration, was left on disk"
# macOS shows every user's process arguments to every other user.
lacks "$CONFIG" "the configuration is never a process argument"
ok "the runner starts from a root-private definition, with its configuration in the job's environment only"
grep -q '^gh .*ghp_POOL' "$tmp/calls" && fail "the token was a process argument"
grep -q 'ghp_POOL' "$job" && fail "the token reached the runner's job"
ok "the token reaches gh and nothing else"
has "launchctl bootout gui/502/$POOL_LABEL-1" "the finished job is removed"
has '-X DELETE orgs/autumngarage/actions/runners/4242' "the registration is forgotten"
[ -z "$(ls "$tmp/state")" ] || fail "a finished slot left state behind: $(ls "$tmp/state")"
grep -Fq 'exited (0)' "$tmp/out" || fail "the exit was not logged: $(cat "$tmp/out")"
ok "after the job, the runner's job and registration are gone and the slot's state removed"
lacks '^as ci .*config.sh' "no runner is registered with an organization token in the account"

echo "==> slots run side by side and keep their files"
SLOTS=2 runner run
[ "$rc" -eq 0 ] || fail "a two-slot run exited $rc: $(cat "$tmp/out")"
has "launchctl bootstrap gui/502 $tmp/state/slot-2.plist" "slot 2"
has 'name=ci-studio-pool-2-' "slot 2's runner"
[ -x "$home/actions-runner-pool-2/run.sh" ] || fail "slot 2 has no runner files"
lacks "rsync .*actions-runner-pool-1/" "a slot that has its files"
ok "each slot has its own directory and job, and a prepared slot is not copied again"

echo "==> a runner left running by an earlier supervisor finishes first"
leftover() { echo 2 >"$tmp/fake/job-$POOL_LABEL-1"; echo 0 >"$tmp/fake/job-$POOL_LABEL-1.rc"; }
BEFORE=leftover runner run
[ "$rc" -eq 0 ] || fail "adopting a running job exited $rc: $(cat "$tmp/out")"
[ "$(line_of 'sleep 10')" -lt "$(line_of 'generate-jitconfig')" ] || fail "a new runner was registered while the old one ran: $(cat "$tmp/calls")"
ok "the slot waits for its running job before registering another"

echo "==> what a slot's job left running is ended before its next job (AUT-2076)"
FLAGS=leftover runner run
[ "$rc" -eq 0 ] || fail "a run with leftovers exited $rc: $(cat "$tmp/out")"
has "pgrep -U 502 -f $home/actions-runner-pool-1/_work/" "the leftovers are found by this slot's work directory"
has 'kill -TERM 4101 4102' "the leftovers are asked to end"
lacks '^kill -KILL' "processes that ended on SIGTERM are not killed"
[ "$(line_of 'kill -TERM')" -lt "$(line_of 'generate-jitconfig')" ] || fail "the next runner was registered before the leftovers were ended: $(cat "$tmp/calls")"
FLAGS="leftover resist" runner run
has 'kill -KILL 4102' "a leftover that ignores SIGTERM is killed"
SLOTS=2 FLAGS=leftover runner run
grep -q "pgrep -U 502 -f $home/actions-runner-pool-2/_work/" "$tmp/calls" || fail "slot 2 was not checked for its own leftovers"
[ "$(grep -c '^kill -TERM' "$tmp/calls")" -eq 1 ] || fail "a slot ended another slot's processes: $(grep '^kill' "$tmp/calls")"
# A process whose arguments name this slot's work directory but that runs
# under another slot's live runner belongs to a running job: never ended.
FLAGS="leftover foreign" runner run
has 'kill -TERM 4101 4102' "the orphaned leftovers are still ended"
grep '^kill' "$tmp/calls" | grep -q 4103 && fail "a process under another slot's live runner was signalled: $(grep '^kill' "$tmp/calls")"
ok "leftovers are ended by slot, TERM then KILL, before the slot registers again"

echo "==> the account must be logged in"
FLAGS=no-session runner run
refused 'ci is not logged in' "an account with no login session"
lacks 'generate-jitconfig' "no session"
FLAGS=session-drops runner run
[ "$rc" -eq 0 ] || fail "a session that returns exited $rc: $(cat "$tmp/out")"
[ "$(line_of 'sleep 15')" -lt "$(line_of 'generate-jitconfig')" ] || fail "a runner was registered with no session: $(cat "$tmp/calls")"
ok "no session registers nothing; a slot waits for the session to return"

echo "==> a lost session restarts the Mac only when that is safe and useful"
now="$(date +%s)"
lost_at() { echo "$1" >"$tmp/state/session-lost-since"; }
long_lost() { lost_at $((now - 900)); }
# Off unless asked for: the default never restarts, however long it has been.
FLAGS=no-session BEFORE=long_lost runner run
refused 'ci is not logged in' "a lost session with no restart configured"
lacks 'restart' "the default"
# Asked for, but only just lost: the moment is remembered, nothing restarts.
FLAGS=no-session RESTART_AFTER=300 runner run
lacks 'restart' "a session lost a moment ago"
[ "$(cat "$tmp/state/session-lost-since")" -ge "$now" ] || fail "the moment the session was lost was not recorded"
# Lost for longer than the limit, nobody at the console, auto-login is the
# account's: one restart, recorded, and the mark cleared so the next boot
# starts its own count.
FLAGS=no-session RESTART_AFTER=300 BEFORE=long_lost runner run
has 'restart now' "a session lost for 900s"
[ "$(grep -c '^restart' "$tmp/calls")" -eq 1 ] || fail "restarted more than once: $(grep '^restart' "$tmp/calls")"
[ "$(grep -c . "$tmp/state/restarts")" -eq 1 ] || fail "the restart was not recorded"
[ ! -e "$tmp/state/session-lost-since" ] || fail "the mark survived the restart; the next boot would restart again at once"
grep -q 'restarting the Mac so auto-login restores it' "$tmp/logs/pool.log" 2>/dev/null \
  || grep -q 'restarting the Mac so auto-login restores it' "$tmp/out" || fail "the restart was not logged: $(cat "$tmp/out")"
# Never under a person.
someone() { long_lost; echo henry >"$tmp/fake/console"; }
FLAGS=no-session RESTART_AFTER=300 BEFORE=someone runner run
lacks 'restart' "someone at the console"
grep -q 'henry is at the console' "$tmp/out" || fail "the reason was not logged: $(cat "$tmp/out")"
# An owner that cannot be read is not "nobody": an empty answer and a probe
# that fails both hold the restart.
unreadable() { long_lost; : >"$tmp/fake/console"; }
FLAGS=no-session RESTART_AFTER=300 BEFORE=unreadable runner run
lacks 'restart' "a console owner that reads as empty"
grep -q "console's owner could not be read" "$tmp/out" || fail "the unreadable console was not named: $(cat "$tmp/out")"
FLAGS="no-session console-fails" RESTART_AFTER=300 BEFORE=long_lost runner run
lacks 'restart' "a console probe that fails"
# Never when a restart would not bring the session back.
other_autologin() { long_lost; echo henry >"$tmp/fake/autologin"; }
FLAGS=no-session RESTART_AFTER=300 BEFORE=other_autologin runner run
lacks 'restart' "auto-login for another account"
FLAGS="no-session no-autologin" RESTART_AFTER=300 BEFORE=long_lost runner run
lacks 'restart' "auto-login off"
grep -q "auto-login is 'off'" "$tmp/out" || fail "auto-login off was not named: $(cat "$tmp/out")"
# Never a loop: two restarts in the last day and it waits for a person; a
# restart older than a day does not count.
twice() { long_lost; printf '%s\n%s\n' $((now - 7200)) $((now - 3600)) >"$tmp/state/restarts"; }
FLAGS=no-session RESTART_AFTER=300 BEFORE=twice runner run
lacks 'restart' "two restarts already today"
grep -q 'already restarted 2 times' "$tmp/out" || fail "the restart limit was not named: $(cat "$tmp/out")"
once_and_old() { long_lost; printf '%s\n%s\n' $((now - 200000)) $((now - 3600)) >"$tmp/state/restarts"; }
FLAGS=no-session RESTART_AFTER=300 BEFORE=once_and_old runner run
has 'restart now' "one restart today and one two days ago"
# A mark from before this boot is not this boot's: the count starts at boot.
just_booted() { long_lost; echo $((now - 60)) >"$tmp/fake/boot"; }
FLAGS=no-session RESTART_AFTER=300 BEFORE=just_booted runner run
lacks 'restart' "a mark older than the boot, one minute after boot"
[ "$(cat "$tmp/state/session-lost-since")" -eq $((now - 60)) ] || fail "the mark was not moved up to the boot time: $(cat "$tmp/state/session-lost-since")"
# A session that is there clears the mark.
RESTART_AFTER=300 BEFORE=long_lost runner run
[ "$rc" -eq 0 ] || fail "a run with a session exited $rc: $(cat "$tmp/out")"
[ ! -e "$tmp/state/session-lost-since" ] || fail "a returned session left its mark"
lacks 'restart' "a session that is up"
# A session that outlived its window server is lost too (AUT-2255): launchd
# still has the account's domain, and nothing in it can reach the display.
# Nothing is registered into it, the log says which kind of loss it is, and
# the restart follows the same rules.
FLAGS=stale-session runner run
refused 'older than the window server' "a session that predates the window server"
lacks 'generate-jitconfig' "a stale session"
lacks 'restart' "a stale session with no restart configured"
FLAGS=stale-session RESTART_AFTER=300 runner run
lacks 'restart' "a session that went stale a moment ago"
[ "$(cat "$tmp/state/session-lost-since")" -ge "$now" ] || fail "the moment the session went stale was not recorded"
FLAGS=stale-session RESTART_AFTER=300 BEFORE=long_lost runner run
has 'restart now' "a session stale for 900s"
[ "$(grep -c '^restart' "$tmp/calls")" -eq 1 ] || fail "a stale session restarted more than once: $(grep '^restart' "$tmp/calls")"
grep -q 'older than the window server.*restarting the Mac so auto-login restores it' "$tmp/out" || fail "the restart did not say the session was stale: $(cat "$tmp/out")"
FLAGS=stale-session RESTART_AFTER=300 BEFORE=someone runner run
lacks 'restart' "a stale session with someone at the console"
grep -q 'older than the window server.*henry is at the console' "$tmp/out" || fail "the hold did not name the stale session and the person: $(cat "$tmp/out")"
# A session that goes stale under a running job: the slot is waiting on that
# job, and the count toward the restart starts there, not when the job ends.
FLAGS=stale-while-running RESTART_AFTER=300 POLLS=2 runner run
[ "$rc" -eq 0 ] || fail "a run whose session went stale under its job exited $rc: $(cat "$tmp/out")"
has 'generate-jitconfig' "a session that was fresh when the runner registered"
[ -f "$tmp/state/session-lost-since" ] || fail "a session that went stale while the slot waited on its job did not start the restart's count: $(cat "$tmp/out")"
lacks 'restart' "a session stale for less than the limit under a running job"
# A session lost and back before the limit leaves no mark: the next loss
# counts from its own start, not from the earlier one.
FLAGS=session-drops RESTART_AFTER=300 runner run
[ "$rc" -eq 0 ] || fail "a session that returns exited $rc: $(cat "$tmp/out")"
lacks 'restart' "a session that came back before the limit"
[ ! -e "$tmp/state/session-lost-since" ] || fail "a session that came back left its mark for the next loss to inherit"
# The setting is a number, and installing it needs the account's auto-login.
RESTART_AFTER=soon runner run
refused 'must be a number of seconds' "a restart setting that is not a number"
FLAGS=no-autologin RESTART_AFTER=300 runner install-daemon
refused 'needs auto-login set to ci' "installing the restart without auto-login"
RESTART_AFTER=300 runner install-daemon
[ "$rc" -eq 0 ] || fail "install-daemon with a restart setting exited $rc: $(cat "$tmp/out")"
grep -q '<key>MACOS_RUNNER_RESTART_AFTER</key><string>300</string>' "$tmp/daemons/com.autumngarage.macos-pool-runner.plist" \
  || fail "the daemon was not given the restart setting"
ok "a lost session restarts once, never under a person, never without auto-login, never in a loop"

echo "==> failures back off instead of spinning"
FLAGS=jit-fails runner run
[ "$rc" -eq 0 ] || fail "a recovered registration failure exited $rc"
has 'sleep 15' "registration failure"
ok "a failed registration waits, then retries"
FLAGS=jit-garbage runner run
[ "$rc" -eq 0 ] || fail "a recovered bad configuration exited $rc: $(cat "$tmp/out")"
has '-X DELETE orgs/autumngarage/actions/runners/4141' "a runner with a bad configuration is forgotten"
[ "$(cat "$tmp/fake/configs")" = "$CONFIG" ] || fail "a configuration that is not base64 reached a job: $(cat "$tmp/fake/configs")"
ok "a configuration that is not base64 is never written into a job"
FLAGS=bootstrap-fails runner run
[ "$rc" -eq 0 ] || fail "a recovered launchd failure exited $rc: $(cat "$tmp/out")"
[ "$(grep -c -- '-X DELETE orgs/autumngarage/actions/runners/4242' "$tmp/calls")" -eq 2 ] \
  || fail "the runner launchd would not start was not forgotten: $(cat "$tmp/calls")"
has 'sleep 15' "launchd failure"
[ ! -e "$tmp/state/slot-1.plist" ] || fail "a refused job definition was left on disk"
ok "a runner launchd will not start is forgotten, and its definition removed"
POLLS=0 JOB_RC=78 runner run
has 'sleep 15' "a runner that dies at once"
grep -Fq 'exited (78)' "$tmp/out" || fail "the runner's exit code was not logged: $(cat "$tmp/out")"
ok "a runner that dies at once waits before the next registration"

echo "==> it registers only into exactly one private runner group"
for flag in no-group broad-group public-allowed public-repo empty-group; do
  FLAGS=$flag runner run
  [ "$rc" -ne 0 ] || fail "$flag: a runner group that could admit untrusted code was accepted"
  lacks 'generate-jitconfig' "$flag"
done
ok "a missing group, broad visibility, public access, a public repository, or no repositories registers nothing"

echo "==> refusals before anything is registered"
link_slot() { ln -s "$tmp/elsewhere" "$home/actions-runner-pool-1"; }
mkdir -p "$tmp/elsewhere"
rm -rf "$home/actions-runner-pool-1"
BEFORE=link_slot runner run
refused 'is a symlink' "a slot path the account made a symlink"
lacks 'generate-jitconfig' "symlinked slot"
[ -z "$(ls -A "$tmp/elsewhere")" ] || fail "something was written through the symlink"
rm "$home/actions-runner-pool-1"
FLAGS=not-root runner run
refused 'needs root' "a non-root run"
FLAGS=no-user runner run
refused "no local user 'ci'" "a missing account"
mv "$first/.runner" "$tmp/runner.bak"
runner run
refused 'is not a configured runner' "an account with no first runner"
mv "$tmp/runner.bak" "$first/.runner"
chmod 644 "$tmp/tok/token"
runner run
refused 'make it private' "a readable token file"
chmod 600 "$tmp/tok/token"
SLOTS=0 runner run
refused 'must be a positive integer' "zero slots"
lacks 'generate-jitconfig' "every refusal"
ok "a symlinked slot, no root, no account, no first runner, a readable token, or no slots registers nothing"

echo "==> install-daemon runs an installed copy as root at boot"
seed_token() {
  printf 'ghp_DAEMON\n' >"$tmp/state/github-token"
  chmod "${TOKEN_MODE:-600}" "$tmp/state/github-token"
}
BEFORE=seed_token TOKEN_FILE="$tmp/state/github-token" runner install-daemon
[ "$rc" -eq 0 ] || fail "install-daemon exited $rc: $(cat "$tmp/out")"
dplist="$tmp/daemons/com.autumngarage.macos-pool-runner.plist"
[ -f "$dplist" ] || fail "install-daemon wrote no LaunchDaemon"
grep -Fq "<string>$tmp/state/macos-runner.sh</string>" "$dplist" || fail "the daemon does not run the installed copy"
cmp -s "$tmp/state/macos-runner.sh" "$script" || fail "install-daemon did not copy the supervisor"
cmp -s "$tmp/state/jit.sh" "$root/runner/jit.sh" || fail "install-daemon did not copy runner/jit.sh beside the supervisor"
grep -q '<key>UserName</key>' "$dplist" && fail "the daemon must run as root to start jobs in the account's session"
grep -Fq '<key>MACOS_RUNNER_USER</key><string>ci</string>' "$dplist" || fail "the daemon does not name the account"
grep -Fq "<key>MACOS_RUNNER_TOKEN_FILE</key><string>$tmp/state/github-token</string>" "$dplist" || fail "the daemon has no token file"
grep -Fq 'ghp_DAEMON' "$dplist" && fail "the token was written into the plist"
has 'gh-token ghp_DAEMON' "install checks the token against the group"
has 'launchctl bootstrap system' "install-daemon"
ok "the LaunchDaemon runs a copy of the supervisor and jit.sh as root, with root's private token"
FLAGS=not-root BEFORE=seed_token TOKEN_FILE="$tmp/state/github-token" runner install-daemon
refused 'needs root' "a non-root install"
TOKEN_FILE="$tmp/state/github-token" runner install-daemon
refused 'no token at' "a missing token"
TOKEN_MODE=644 BEFORE=seed_token TOKEN_FILE="$tmp/state/github-token" runner install-daemon
refused 'must be private to root' "a readable token"
FLAGS=broad-group BEFORE=seed_token TOKEN_FILE="$tmp/state/github-token" runner install-daemon
refused 'must be visible only to selected repositories' "an open runner group"
[ ! -f "$dplist" ] || fail "a refused install left a LaunchDaemon"
ok "install-daemon refuses without root, root's private token, or a private runner group"
# Replacing a running daemon (AUT-2258): launchd is still ending the old one
# when bootout returns, and a load in that window fails with the old one
# already gone. install-daemon waits for it to leave and tries the load again.
FLAGS=daemon-lingers BEFORE=seed_token TOKEN_FILE="$tmp/state/github-token" runner install-daemon
[ "$rc" -eq 0 ] || fail "install-daemon over a daemon that was still leaving exited $rc: $(cat "$tmp/out")"
[ "$(line_of 'sleep 1')" -lt "$(line_of 'launchctl bootstrap system')" ] || fail "the new daemon was loaded before the old one had left: $(cat "$tmp/calls")"
FLAGS=daemon-busy BEFORE=seed_token TOKEN_FILE="$tmp/state/github-token" runner install-daemon
[ "$rc" -eq 0 ] || fail "install-daemon gave up on a load launchd refused twice: $(cat "$tmp/out")"
[ "$(grep -c 'launchctl bootstrap system' "$tmp/calls")" -eq 3 ] || fail "expected the load to be tried three times: $(grep 'bootstrap system' "$tmp/calls")"
# A load that never succeeds is given up on after the wait, and the message
# is the command that starts the pool, because the old daemon is gone.
FLAGS=daemon-stuck BEFORE=seed_token TOKEN_FILE="$tmp/state/github-token" runner install-daemon
refused "sudo launchctl bootstrap system" "a daemon launchd will not load"
grep -q 'the old service is stopped and the pool is not running' "$tmp/out" || fail "the refusal did not say the pool is stopped: $(cat "$tmp/out")"
grep -q 'Input/output error' "$tmp/out" || fail "the refusal did not carry launchd's reason: $(cat "$tmp/out")"
# An old daemon that outlives the wait is still the service launchd lists, so
# finding one there is not the new daemon loaded: the install fails, having
# tried no load, and names the command for when the old one has gone.
FLAGS=daemon-stays BEFORE=seed_token TOKEN_FILE="$tmp/state/github-token" runner install-daemon
refused "sudo launchctl bootstrap system" "an install over a daemon that never left"
grep -q 'was still in launchd 60s after its bootout' "$tmp/out" || fail "the refusal did not say the old daemon was still there: $(cat "$tmp/out")"
lacks 'launchctl bootstrap system' "an install over a daemon that never left"
grep -q 'installed com.autumngarage.macos-pool-runner' "$tmp/out" && fail "an install over a daemon that never left reported success: $(cat "$tmp/out")"
ok "install-daemon waits for the daemon it replaces, retries the load, and names the command if it cannot"
runner uninstall-daemon
[ "$rc" -eq 0 ] || fail "uninstall-daemon exited $rc"
has 'launchctl bootout system/com.autumngarage.macos-pool-runner' "uninstall-daemon"
ok "uninstall-daemon boots the daemon out"

echo "macOS runner pool passed"
