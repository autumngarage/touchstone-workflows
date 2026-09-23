#!/usr/bin/env bash
# runner/linux-runner.sh (AUT-1596): every job gets a single-use registration
# and a fresh container that holds nothing but that registration. `validate`
# runs candidate code on these runners, so this is its security boundary.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/runner/linux-runner.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "  OK: $*"; }

bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$FAKE_CALLS"
[ -n "${GH_TOKEN:-}" ] && printf 'gh-token %s\n' "$GH_TOKEN" >>"$FAKE_CALLS"
case "$*" in
  *runner-groups/*/repositories*)
    [ -f "$FAKE_STATE/empty-group" ] && exit 0
    echo "autumngarage/vesper true"
    [ -f "$FAKE_STATE/public-repo" ] && echo "autumngarage/touchstone false"
    exit 0
    ;;
  *actions/runner-groups*)
    [ -f "$FAKE_STATE/no-group" ] && exit 0
    visibility=selected
    [ -f "$FAKE_STATE/broad-group" ] && visibility=all
    public=false
    [ -f "$FAKE_STATE/public-allowed" ] && public=true
    echo "{\"id\":7,\"visibility\":\"$visibility\",\"allows_public_repositories\":$public}"
    [ -f "$FAKE_STATE/two-groups" ] && echo '{"id":9,"visibility":"selected","allows_public_repositories":false}'
    exit 0
    ;;
  *generate-jitconfig*)
    if [ -f "$FAKE_STATE/jit-fails" ] && [ ! -f "$FAKE_STATE/jit-failed" ]; then
      touch "$FAKE_STATE/jit-failed"
      echo "HTTP 502: Bad Gateway" >&2
      exit 1
    fi
    echo '{"runner":{"id":4242},"encoded_jit_config":"SINGLE-USE-CONFIG"}'
    ;;
  # GitHub has already removed a single-use runner that took its job.
  *"-X DELETE"*) exit 1 ;;
esac
EOF
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$FAKE_CALLS"
case "$1" in
  image) [ ! -f "$FAKE_STATE/no-image" ] ;;
  run)
    # What the container reads on stdin, where the configuration must arrive.
    printf 'docker-stdin %s\n' "$(cat)" >>"$FAKE_CALLS"
    exit "${FAKE_DOCKER_RC:-0}"
    ;;
  *) exit 0 ;;
esac
EOF
cat >"$bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$FAKE_CALLS"
EOF
cat >"$bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo testhost
EOF
cat >"$bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$FAKE_CALLS"
EOF
cat >"$bin/colima" <<'EOF'
#!/usr/bin/env bash
printf 'colima %s\n' "$*" >>"$FAKE_CALLS"
case "$1" in
  status) [ -f "$FAKE_STATE/colima-up" ] ;;
  start) [ ! -f "$FAKE_STATE/colima-fails" ] ;;
esac
EOF
# id: root unless the not-root flag is set; the user and group names the
# daemon install asks for are the real ones, so stat's owner check agrees.
real_user="$(id -un)"
real_group="$(id -gn)"
cat >"$bin/id" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -u) if [ -f "\$FAKE_STATE/not-root" ]; then echo 501; else echo 0; fi ;;
  -un) echo "$real_user" ;;
  -gn) echo "$real_group" ;;
esac
EOF
cat >"$bin/dscl" <<'EOF'
#!/usr/bin/env bash
[ -f "$FAKE_STATE/no-user" ] && exit 56
echo "NFSHomeDirectory: $FAKE_HOME"
EOF
cat >"$bin/chown" <<'EOF'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >>"$FAKE_CALLS"
EOF
chmod +x "$bin"/*

# runner ARGS...: run the script against the fakes with a fresh call log and
# state; stdout+stderr land in $tmp/out and the exit code in $rc.
runner() {
  rm -rf "${tmp:?}/state" "${tmp:?}/fake" "${tmp:?}/daemons"
  [ -n "${KEEP_HOME:-}" ] || rm -rf "${tmp:?}/home"
  mkdir -p "$tmp/state" "$tmp/fake" "$tmp/home"
  : >"$tmp/calls"
  for flag in ${FLAGS:-}; do touch "$tmp/fake/$flag"; done
  set +e
  PATH="$bin:$PATH" HOME="$tmp/home" FAKE_CALLS="$tmp/calls" FAKE_STATE="$tmp/fake" \
    LINUX_RUNNER_STATE_DIR="$tmp/state" LINUX_RUNNER_SLOTS="${SLOTS:-1}" \
    LINUX_RUNNER_MAX_JOBS="${JOBS:-1}" FAKE_DOCKER_RC="${DOCKER_RC:-0}" \
    LINUX_RUNNER_ENGINE="${ENGINE:-docker}" LINUX_RUNNER_TOKEN_FILE="${TOKEN_FILE:-}" \
    LINUX_RUNNER_DAEMON_DIR="$tmp/daemons" FAKE_HOME="$tmp/home" \
    bash "$script" "$@" >"$tmp/out" 2>&1
  rc=$?
  set -e
}
has() { grep -Fq -- "$1" "$tmp/calls" || fail "$2: expected '$1' in: $(cat "$tmp/calls")"; }
lacks() { ! grep -Eq -- "$1" "$tmp/calls" || fail "$2: unexpected '$1' in: $(cat "$tmp/calls")"; }

echo "==> one job: a single-use registration and a container that holds only it"
runner run
[ "$rc" -eq 0 ] || fail "a clean one-job run exited $rc: $(cat "$tmp/out")"
has 'generate-jitconfig' "registration"
has 'runner_group_id=7' "registration binds the runner group"
# The workflows select ["self-hosted", LINUX_RUNNER]. A just-in-time runner
# carries only the labels it is registered with, so it must be given both, or
# every job waits forever for a runner that never matches.
has 'labels[]=self-hosted' "registration carries the self-hosted label every selector requires"
has 'labels[]=linux-ephemeral' "registration carries the label LINUX_RUNNER names"
run_line="$(grep '^docker run ' "$tmp/calls")"
# --pids-limit keeps a pull request that forks without end inside its own
# container instead of exhausting the VM every slot shares.
# The last literal is the container's own command text, matched as written.
# shellcheck disable=SC2016
for arg in '--rm' '--init' ' -i ' '--memory 6g' '--cpus 4' '--pids-limit 4096' '--pull never' 'exec ./run.sh --jitconfig "$jit"'; do
  case "$run_line" in *"$arg"*) ;; *) fail "container is missing '$arg': $run_line" ;; esac
done
for forbidden in ' -v ' '--volume' '--mount' '--privileged' 'docker.sock' '--network' ' -e ' '--env' 'GH_TOKEN' '--cap-add'; do
  case "$run_line" in *"$forbidden"*) fail "container must not get '$forbidden': $run_line" ;; esac
done
# macOS shows every user's process arguments to every other user: the
# configuration is a runner credential, so it reaches the container on stdin
# and never appears in the host's docker arguments.
case "$run_line" in *SINGLE-USE-CONFIG*) fail "the single-use configuration is a host process argument: $run_line" ;; esac
has 'docker-stdin SINGLE-USE-CONFIG' "the configuration arrives on the container's stdin"
ok "the container gets the single-use configuration, on stdin, and nothing else"
has '-X DELETE orgs/autumngarage/actions/runners/4242' "cleanup"
[ -z "$(ls "$tmp/state")" ] || fail "a finished slot left state behind: $(ls "$tmp/state")"
ok "the registration is forgotten and the slot's state removed after the job"

echo "==> failures back off instead of spinning"
FLAGS=jit-fails runner run
[ "$rc" -eq 0 ] || fail "a recovered registration failure exited $rc"
has 'sleep 15' "registration failure"
[ "$(grep -c '^docker run ' "$tmp/calls")" -eq 1 ] || fail "expected one container after the retry"
ok "a failed registration waits, then retries"
DOCKER_RC=125 runner run
has 'sleep 15' "immediate container failure"
ok "a container that dies at once waits before the next registration"

echo "==> it registers only into exactly one named group, with an image present"
# refused TEXT LABEL: the last run failed and said TEXT.
refused() {
  if [ "$rc" -eq 0 ] || ! grep -Fq -- "$1" "$tmp/out"; then
    fail "$2 was not refused (exit $rc): $(cat "$tmp/out")"
  fi
}
FLAGS=no-group runner run
refused "expected one runner group named 'linux-ephemeral'" "a missing group"
lacks '^docker run ' "missing group"
FLAGS=two-groups runner run
refused 'found 2' "two same-named groups"
ok "a missing or ambiguous runner group registers nothing"
# The group is the host's trust boundary: a public repository takes fork pull
# requests, so a group that could ever admit one must register nothing.
for flag in broad-group public-allowed public-repo empty-group; do
  FLAGS=$flag runner run
  [ "$rc" -ne 0 ] || fail "$flag: a runner group that could admit untrusted code was accepted"
  lacks 'generate-jitconfig' "$flag"
done
ok "a group with broad visibility, public access, a public repository, or no repositories registers nothing"
FLAGS=no-image runner run
refused 'runner/linux-runner.sh build' "a missing image"
lacks 'generate-jitconfig' "missing image"
ok "a missing image registers nothing"
SLOTS=0 runner run
[ "$rc" -ne 0 ] || fail "zero slots was accepted"
ok "the slot count must be a positive integer"

echo "==> install runs the supervisor from a copy, kept awake"
runner install
[ "$rc" -eq 0 ] || fail "install exited $rc: $(cat "$tmp/out")"
plist="$tmp/home/Library/LaunchAgents/com.autumngarage.linux-ephemeral-runner.plist"
[ -f "$plist" ] || fail "install wrote no LaunchAgent"
grep -Fq '<string>/usr/bin/caffeinate</string>' "$plist" || fail "the agent is not kept awake"
grep -Fq "<string>$tmp/state/linux-runner.sh</string>" "$plist" || fail "the agent does not run the installed copy"
[ -f "$tmp/state/linux-runner.sh" ] || fail "install did not copy the supervisor"
grep -Fq '<key>LINUX_RUNNER_LABEL</key><string>linux-ephemeral</string>' "$plist" || fail "the agent lost its label"
has 'launchctl bootstrap' "install"
ok "the LaunchAgent runs a copy of the supervisor under caffeinate"

echo "==> a headless host starts its own Colima VM"
ENGINE=colima runner run
[ "$rc" -eq 0 ] || fail "a colima run exited $rc: $(cat "$tmp/out")"
has 'colima start --vm-type vz' "a stopped VM"
has 'docker run ' "colima run"
FLAGS=colima-up ENGINE=colima runner run
lacks '^colima start' "a running VM"
ok "the VM is started when it is down, and left alone when it is up"
FLAGS=colima-fails ENGINE=colima runner run
refused 'colima could not start its VM' "a VM that will not start"
lacks 'generate-jitconfig' "no VM"
ok "a VM that will not start registers nothing"
runner run
lacks '^colima' "the default engine"
ok "the default engine never touches Colima"

echo "==> a token file is private, reaches gh, and never a container"
mkdir -p "$tmp/tok"
printf 'ghp_FILETOKEN\n' >"$tmp/tok/token"
chmod 644 "$tmp/tok/token"
TOKEN_FILE="$tmp/tok/token" runner run
refused 'make it private' "a readable token file"
lacks 'generate-jitconfig' "readable token"
chmod 600 "$tmp/tok/token"
TOKEN_FILE="$tmp/tok/token" runner run
[ "$rc" -eq 0 ] || fail "a private token file run exited $rc: $(cat "$tmp/out")"
has 'gh-token ghp_FILETOKEN' "gh gets the file's token"
if grep '^docker run ' "$tmp/calls" | grep -q 'FILETOKEN'; then fail "the token reached the container"; fi
ok "gh runs with the file's token, and the container never sees it"

echo "==> install-daemon runs the fleet at boot as its own user"
user_state="$tmp/home/Library/Application Support/linux-ephemeral-runner"
seed_token() {
  rm -rf "${tmp:?}/home"
  mkdir -p "$user_state"
  printf 'ghp_DAEMON\n' >"$user_state/github-token"
  chmod "${1:-600}" "$user_state/github-token"
}
seed_token
KEEP_HOME=1 runner install-daemon "$real_user"
[ "$rc" -eq 0 ] || fail "install-daemon exited $rc: $(cat "$tmp/out")"
dplist="$tmp/daemons/com.autumngarage.linux-ephemeral-runner.plist"
[ -f "$dplist" ] || fail "install-daemon wrote no LaunchDaemon"
grep -Fq "<key>UserName</key><string>$real_user</string>" "$dplist" || fail "the daemon does not run as the fleet's user"
grep -Fq "<key>LINUX_RUNNER_ENGINE</key><string>colima</string>" "$dplist" || fail "the daemon does not use Colima"
grep -Fq "<key>LINUX_RUNNER_TOKEN_FILE</key><string>$user_state/github-token</string>" "$dplist" || fail "the daemon has no token file"
grep -Fq "<string>$user_state/linux-runner.sh</string>" "$dplist" || fail "the daemon does not run the installed copy"
grep -Fq "<key>HOME</key><string>$tmp/home</string>" "$dplist" || fail "the daemon's HOME is not the user's"
grep -Fq 'ghp_DAEMON' "$dplist" && fail "the token was written into the plist"
[ -f "$user_state/linux-runner.sh" ] || fail "install-daemon did not copy the supervisor"
has 'launchctl bootstrap system' "install-daemon"
has "chown $real_user:" "the installed copy belongs to the fleet's user"
ok "the LaunchDaemon runs a copy as the fleet's user, on Colima, with its private token"
seed_token
FLAGS=not-root KEEP_HOME=1 runner install-daemon "$real_user"
refused 'run it with sudo' "a non-root install"
FLAGS=no-user KEEP_HOME=1 runner install-daemon nobody-here
refused "no local user 'nobody-here'" "a missing user"
rm -rf "${tmp:?}/home"; mkdir -p "$tmp/home"
KEEP_HOME=1 runner install-daemon "$real_user"
refused "no token for $real_user" "a missing token"
seed_token 644
KEEP_HOME=1 runner install-daemon "$real_user"
refused 'must be private' "a readable token"
runner install-daemon
refused 'usage: sudo bash runner/linux-runner.sh install-daemon USER' "no user named"
[ ! -f "$tmp/daemons/com.autumngarage.linux-ephemeral-runner.plist" ] || fail "a refused install left a LaunchDaemon"
ok "install-daemon refuses without root, a real user, or that user's private token"
runner uninstall-daemon
[ "$rc" -eq 0 ] || fail "uninstall-daemon exited $rc"
has 'launchctl bootout system/com.autumngarage.linux-ephemeral-runner' "uninstall-daemon"
ok "uninstall-daemon boots the daemon out"

echo "runner supervisor passed"
