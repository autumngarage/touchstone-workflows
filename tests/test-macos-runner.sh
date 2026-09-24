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
      *) exit 113 ;;
    esac
    ;;
  bootstrap)
    [ "$2" != system ] || exit 0
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

echo "==> the account must be logged in"
FLAGS=no-session runner run
refused 'ci is not logged in' "an account with no login session"
lacks 'generate-jitconfig' "no session"
FLAGS=session-drops runner run
[ "$rc" -eq 0 ] || fail "a session that returns exited $rc: $(cat "$tmp/out")"
[ "$(line_of 'sleep 15')" -lt "$(line_of 'generate-jitconfig')" ] || fail "a runner was registered with no session: $(cat "$tmp/calls")"
ok "no session registers nothing; a slot waits for the session to return"

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
runner uninstall-daemon
[ "$rc" -eq 0 ] || fail "uninstall-daemon exited $rc"
has 'launchctl bootout system/com.autumngarage.macos-pool-runner' "uninstall-daemon"
ok "uninstall-daemon boots the daemon out"

echo "macOS runner pool passed"
