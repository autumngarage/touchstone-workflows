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
case "$*" in
  *actions/runner-groups*)
    [ -f "$FAKE_STATE/no-group" ] && exit 0
    echo 7
    [ -f "$FAKE_STATE/two-groups" ] && echo 9
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
  run) exit "${FAKE_DOCKER_RC:-0}" ;;
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
chmod +x "$bin"/*

# runner ARGS...: run the script against the fakes with a fresh call log and
# state; stdout+stderr land in $tmp/out and the exit code in $rc.
runner() {
  rm -rf "${tmp:?}/state" "${tmp:?}/fake" "${tmp:?}/home"
  mkdir -p "$tmp/state" "$tmp/fake" "$tmp/home"
  : >"$tmp/calls"
  for flag in ${FLAGS:-}; do touch "$tmp/fake/$flag"; done
  set +e
  PATH="$bin:$PATH" HOME="$tmp/home" FAKE_CALLS="$tmp/calls" FAKE_STATE="$tmp/fake" \
    LINUX_RUNNER_STATE_DIR="$tmp/state" LINUX_RUNNER_SLOTS="${SLOTS:-1}" \
    LINUX_RUNNER_MAX_JOBS="${JOBS:-1}" FAKE_DOCKER_RC="${DOCKER_RC:-0}" \
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
for arg in '--rm' '--init' '--memory 6g' '--cpus 4' '--pull never' './run.sh --jitconfig SINGLE-USE-CONFIG'; do
  case "$run_line" in *"$arg"*) ;; *) fail "container is missing '$arg': $run_line" ;; esac
done
for forbidden in ' -v ' '--volume' '--mount' '--privileged' 'docker.sock' '--network' ' -e ' '--env' 'GH_TOKEN' '--cap-add'; do
  case "$run_line" in *"$forbidden"*) fail "container must not get '$forbidden': $run_line" ;; esac
done
ok "the container gets the single-use configuration and nothing else"
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

echo "runner supervisor passed"
