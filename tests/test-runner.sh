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
    [ ! -f "$FAKE_STATE/jit-slow" ] || /bin/sleep 2
    echo '{"runner":{"id":4242},"encoded_jit_config":"SINGLE-USE-CONFIG"}'
    ;;
  # GitHub has already removed a single-use runner that took its job.
  *"-X DELETE"*) [ -f "$FAKE_STATE/delete-ok" ] && exit 0; exit 1 ;;
  # The janitor's list: the real jq selects this host's offline runners;
  # stale-runner is one a killed supervisor left.
  *"actions/runners --jq"*)
    [ ! -f "$FAKE_STATE/stale-runner" ] || echo 999
    exit 0
    ;;
  # A registered runner that has not taken its job, while the supervisor drains.
  *"orgs/autumngarage/actions/runners/"*"--jq .busy"*) echo false ;;
esac
EOF
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$FAKE_CALLS"
case "$1" in
  image)
    [ ! -f "$FAKE_STATE/no-image" ] || exit 1
    ;;
  run)
    # What the container reads on stdin, where the configuration must arrive.
    case " $* " in *" -i "*) printf 'docker-stdin %s\n' "$(cat)" >>"$FAKE_CALLS" ;; esac
    echo run >>"$FAKE_STATE/started"
    # A real runner waits for its job; HOLD says for how long.
    /bin/sleep "${FAKE_DOCKER_HOLD:-0}"
    # newsyslog rotating the supervisor's log while a job runs.
    if [ -f "$FAKE_STATE/rotate-log" ] && [ -n "${LINUX_RUNNER_LOG_FILE:-}" ]; then
      mv "$LINUX_RUNNER_LOG_FILE" "$LINUX_RUNNER_LOG_FILE.0"
    fi
    exit "${FAKE_DOCKER_RC:-0}"
    ;;
  ps) cat "$FAKE_STATE/leftovers" 2>/dev/null || true ;;
  *) exit 0 ;;
esac
EOF
cat >"$bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$FAKE_CALLS"
# A test that needs a real wait names its length.
[ "$1" != "${FAKE_REAL_SLEEP_FOR:-}" ] || exec /bin/sleep "$1"
EOF
cat >"$bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo testhost
EOF
cat >"$bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$FAKE_CALLS"
case "$1" in
  print)
    # service-stays: the service being replaced never leaves.
    [ ! -f "$FAKE_STATE/service-stays" ] || exit 0
    # service-lingers: it is still there for the first two looks after its
    # bootout. Otherwise nothing is loaded.
    [ -f "$FAKE_STATE/service-lingers" ] || exit 113
    count="$(cat "$FAKE_STATE/linger-count" 2>/dev/null || echo 0)"
    echo $((count + 1)) >"$FAKE_STATE/linger-count"
    [ "$count" -lt 2 ] || exit 113
    ;;
  bootstrap)
    # service-busy: launchd refuses the first two loads, as it does while the
    # old service is still exiting. service-stuck: it refuses them all, as it
    # does (service-stays) over a service that is still loaded.
    if [ -f "$FAKE_STATE/service-stuck" ] || [ -f "$FAKE_STATE/service-stays" ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
    if [ -f "$FAKE_STATE/service-busy" ]; then
      count="$(cat "$FAKE_STATE/busy-count" 2>/dev/null || echo 0)"
      echo $((count + 1)) >"$FAKE_STATE/busy-count"
      if [ "$count" -lt 2 ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
    fi
    ;;
esac
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
# state; stdout+stderr land in $tmp/out and the exit code in $rc. KEEP_FAKE,
# KEEP_HOME and KEEP_DAEMONS keep the fakes' state, the home directory, and the
# installed daemon files from the previous call.
runner() {
  rm -rf "${tmp:?}/state"
  [ -n "${KEEP_DAEMONS:-}" ] || rm -rf "${tmp:?}/daemons" "${tmp:?}/newsyslog"
  [ -n "${KEEP_FAKE:-}" ] || rm -rf "${tmp:?}/fake"
  [ -n "${KEEP_HOME:-}" ] || rm -rf "${tmp:?}/home"
  mkdir -p "$tmp/state" "$tmp/fake" "$tmp/home"
  : >"$tmp/calls"
  for flag in ${FLAGS:-}; do touch "$tmp/fake/$flag"; done
  set +e
  PATH="$bin:$PATH" HOME="$tmp/home" FAKE_CALLS="$tmp/calls" FAKE_STATE="$tmp/fake" \
    LINUX_RUNNER_STATE_DIR="$tmp/state" LINUX_RUNNER_SLOTS="${SLOTS:-1}" \
    LINUX_RUNNER_QUEUE_SLOTS="${QUEUE_SLOTS:-}" \
    LINUX_RUNNER_MAX_JOBS="${JOBS:-1}" FAKE_DOCKER_RC="${DOCKER_RC:-0}" \
    LINUX_RUNNER_ENGINE="${ENGINE:-docker}" LINUX_RUNNER_TOKEN_FILE="${TOKEN_FILE:-}" \
    LINUX_RUNNER_DAEMON_DIR="$tmp/daemons" FAKE_HOME="$tmp/home" \
    LINUX_RUNNER_NEWSYSLOG_DIR="$tmp/newsyslog" FAKE_REAL_SLEEP_FOR=none \
    LINUX_RUNNER_CACHE_SEED="${CACHE_SEED:-}" LINUX_RUNNER_LOG_FILE="${LOG_FILE:-}" \
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
# validate.yml selects ["self-hosted","linux-ephemeral"]. A just-in-time
# runner carries only the labels it is registered with, so it gets exactly
# those two: no role label, so every slot takes every job routed here.
jit_line="$(grep 'generate-jitconfig' "$tmp/calls")"
case "$jit_line" in
  *'-f labels[]=self-hosted -f labels[]=linux-ephemeral -f work_folder=_work') ;;
  *) fail "a runner must register with exactly self-hosted and linux-ephemeral: $jit_line" ;;
esac
[ "$(printf '%s\n' "$jit_line" | grep -o 'labels\[\]=' | grep -c .)" -eq 2 ] \
  || fail "a runner registered with labels beyond the two validate selects: $jit_line"
ok "every runner registers with the labels self-hosted and linux-ephemeral, and no other"
run_line="$(grep '^docker run ' "$tmp/calls")"
# --pids-limit keeps a pull request that forks without end inside its own
# container instead of exhausting the VM every slot shares.
# The last literal is the container's own command text, matched as written.
# shellcheck disable=SC2016
for arg in '--init' ' -i ' '--memory 6g' '--cpus 4' '--pids-limit 4096' '--pull never' 'linux-ephemeral-runner:local bash -c' 'exec ./run.sh --jitconfig "$jit"'; do
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
has 'docker rm -f linux-ephemeral-testhost-1-' "the finished job's container is removed"
[ -z "$(ls "$tmp/state")" ] || fail "a finished slot left state behind: $(ls "$tmp/state")"
ok "the registration is forgotten and the slot's state removed after the job"
SLOTS=3 runner run
[ "$rc" -eq 0 ] || fail "a three-slot run exited $rc: $(cat "$tmp/out")"
for slot in 1 2 3; do
  [ "$(grep 'generate-jitconfig' "$tmp/calls" | grep -c -- "name=linux-ephemeral-testhost-$slot-")" -eq 1 ] \
    || fail "slot $slot did not register exactly once: $(cat "$tmp/calls")"
done
lacks '-shared' "identical slots"
grep -Fq 'supervising 3 identical slot(s)' "$tmp/out" || fail "the slot count is not logged: $(cat "$tmp/out")"
ok "N slots register N identical runners"

echo "==> retired settings an installed wrapper still passes"
for value in '' 0; do
  QUEUE_SLOTS=$value runner run
  [ "$rc" -eq 0 ] || fail "LINUX_RUNNER_QUEUE_SLOTS='$value' was refused: $(cat "$tmp/out")"
done
ok "LINUX_RUNNER_QUEUE_SLOTS unset or 0 is accepted"
for value in 1 3 x; do
  SLOTS=3 QUEUE_SLOTS=$value runner run
  [ "$rc" -ne 0 ] || fail "LINUX_RUNNER_QUEUE_SLOTS=$value was accepted"
  grep -Fq 'LINUX_RUNNER_QUEUE_SLOTS is retired' "$tmp/out" || fail "QUEUE_SLOTS=$value: the refusal does not say why: $(cat "$tmp/out")"
  lacks 'generate-jitconfig' "QUEUE_SLOTS=$value"
done
ok "a nonzero LINUX_RUNNER_QUEUE_SLOTS registers nothing and says the roles are retired"
CACHE_SEED=autumngarage/hesperus:swift-cache.yml runner run
[ "$rc" -eq 0 ] || fail "a run with the retired cache seed exited $rc: $(cat "$tmp/out")"
[ "$(grep -c 'LINUX_RUNNER_CACHE_SEED is retired and ignored' "$tmp/out")" -eq 1 ] \
  || fail "the ignored cache seed is not noted once: $(cat "$tmp/out")"
case "$(grep '^docker run ' "$tmp/calls")" in *"linux-ephemeral-runner:local bash -c"*) ;; *) fail "a job did not start from the base image: $(grep '^docker run ' "$tmp/calls")" ;; esac
lacks 'docker cp|docker commit|actions/workflows|swift-cache' "the retired cache seed"
runner run
! grep -Fq 'CACHE_SEED' "$tmp/out" || fail "an unset cache seed was mentioned: $(cat "$tmp/out")"
ok "LINUX_RUNNER_CACHE_SEED is noted once in the log and ignored; jobs start from the base image"

echo "==> a restart clears what a killed supervisor left"
mkdir -p "$tmp/fake"
printf 'abc123\n' >"$tmp/fake/leftovers"
KEEP_FAKE=1 runner run
has 'docker ps -aq --filter name=^linux-ephemeral-testhost-' "leftovers are looked for"
has 'docker rm -f abc123' "a leftover container is removed"
ok "a restart removes the containers a killed supervisor left"
FLAGS='stale-runner delete-ok' runner run
[ "$rc" -eq 0 ] || fail "a run with a stale registration exited $rc: $(cat "$tmp/out")"
has 'select(.status == "offline" and (.name | startswith("linux-ephemeral-testhost-")))' "the janitor asks only for this host's offline runners"
has '-X DELETE orgs/autumngarage/actions/runners/999' "the stale registration is removed"
line_of() { grep -nF -- "$1" "$tmp/calls" | head -1 | cut -d: -f1; }
[ "$(line_of 'runners/999')" -lt "$(line_of 'generate-jitconfig')" ] \
  || fail "the janitor ran after a slot registered, when an offline runner may be this supervisor's own: $(cat "$tmp/calls")"
grep -Fq 'removed stale offline registration 999' "$tmp/out" || fail "the removal is not logged: $(cat "$tmp/out")"
FLAGS='stale-runner' runner run
grep -Fq 'could not remove stale offline registration 999' "$tmp/out" || fail "a refused removal is not logged: $(cat "$tmp/out")"
ok "before any slot registers, this host's offline registrations are removed, and a refusal is logged"

echo "==> a stop signal drains: running jobs finish, nothing new registers (AUT-2763)"
# A supervisor holding two jobs (4 s each). The first TERM arrives while they
# run: both must finish, no third runner may register, and it exits cleanly.
# Job control gives the supervisor its own process group, which stop_slots ends.
set -m
rm -rf "${tmp:?}/state" "${tmp:?}/fake" "${tmp:?}/home"
mkdir -p "$tmp/state" "$tmp/fake" "$tmp/home"
: >"$tmp/calls"
touch "$tmp/fake/delete-ok"
PATH="$bin:$PATH" HOME="$tmp/home" FAKE_CALLS="$tmp/calls" FAKE_STATE="$tmp/fake" \
  LINUX_RUNNER_STATE_DIR="$tmp/state" LINUX_RUNNER_SLOTS=2 LINUX_RUNNER_MAX_JOBS=5 \
  LINUX_RUNNER_ENGINE=docker LINUX_RUNNER_TOKEN_FILE="" LINUX_RUNNER_DAEMON_DIR="$tmp/daemons" \
  FAKE_HOME="$tmp/home" FAKE_DOCKER_HOLD=4 FAKE_DOCKER_RC=0 FAKE_REAL_SLEEP_FOR=none \
  LINUX_RUNNER_DRAIN_INTERVAL=1 \
  bash "$script" run >"$tmp/out" 2>&1 &
sup=$!
until [ "$(grep -c '^run$' "$tmp/fake/started" 2>/dev/null || echo 0)" -ge 2 ]; do /bin/sleep 0.2; done
kill -TERM "$sup"
/bin/sleep 1
kill -0 "$sup" 2>/dev/null || fail "a stop signal ended the supervisor while jobs were running: $(cat "$tmp/out")"
rc=0; wait "$sup" || rc=$?
[ "$rc" -eq 0 ] || fail "a drained supervisor exited $rc: $(cat "$tmp/out")"
[ "$(grep -c 'generate-jitconfig' "$tmp/calls")" -eq 2 ] \
  || fail "a runner registered after the stop signal: $(grep generate-jitconfig "$tmp/calls")"
grep -Fq 'draining' "$tmp/out" || fail "the drain is not logged: $(cat "$tmp/out")"
[ ! -e "$tmp/state/draining" ] || fail "the drain marker outlived the supervisor"
ok "the first stop signal lets running jobs finish and registers nothing more"
# A second signal stops at once.
rm -rf "${tmp:?}/state" "${tmp:?}/fake"
mkdir -p "$tmp/state" "$tmp/fake"
: >"$tmp/calls"
PATH="$bin:$PATH" HOME="$tmp/home" FAKE_CALLS="$tmp/calls" FAKE_STATE="$tmp/fake" \
  LINUX_RUNNER_STATE_DIR="$tmp/state" LINUX_RUNNER_SLOTS=1 LINUX_RUNNER_MAX_JOBS=5 \
  LINUX_RUNNER_ENGINE=docker LINUX_RUNNER_TOKEN_FILE="" LINUX_RUNNER_DAEMON_DIR="$tmp/daemons" \
  FAKE_HOME="$tmp/home" FAKE_DOCKER_HOLD=30 FAKE_DOCKER_RC=0 FAKE_REAL_SLEEP_FOR=none \
  bash "$script" run >"$tmp/out" 2>&1 &
sup=$!
until [ -f "$tmp/fake/started" ]; do /bin/sleep 0.2; done
kill -TERM "$sup"; /bin/sleep 0.5; kill -TERM "$sup"
/bin/sleep 1
! kill -0 "$sup" 2>/dev/null || { kill -KILL "$sup" 2>/dev/null; fail "a second stop signal did not stop the supervisor"; }
wait "$sup" 2>/dev/null || true
ok "a second stop signal stops at once"
# A stop signal that arrives while a runner is being registered must not leave
# that runner waiting: the registration finishes, and the drain removes it.
rm -rf "${tmp:?}/state" "${tmp:?}/fake"
mkdir -p "$tmp/state" "$tmp/fake"
: >"$tmp/calls"
touch "$tmp/fake/delete-ok" "$tmp/fake/jit-slow"
PATH="$bin:$PATH" HOME="$tmp/home" FAKE_CALLS="$tmp/calls" FAKE_STATE="$tmp/fake" \
  LINUX_RUNNER_STATE_DIR="$tmp/state" LINUX_RUNNER_SLOTS=1 LINUX_RUNNER_MAX_JOBS=5 \
  LINUX_RUNNER_ENGINE=docker LINUX_RUNNER_TOKEN_FILE="" LINUX_RUNNER_DAEMON_DIR="$tmp/daemons" \
  FAKE_HOME="$tmp/home" FAKE_DOCKER_HOLD=4 FAKE_DOCKER_RC=0 FAKE_REAL_SLEEP_FOR=none \
  LINUX_RUNNER_DRAIN_INTERVAL=1 \
  bash "$script" run >"$tmp/out" 2>&1 &
sup=$!
until grep -q 'generate-jitconfig' "$tmp/calls"; do /bin/sleep 0.1; done
kill -TERM "$sup"
rc=0; wait "$sup" || rc=$?
[ "$rc" -eq 0 ] || fail "a supervisor stopped during a registration exited $rc: $(cat "$tmp/out")"
[ "$(grep -c -- '-X DELETE' "$tmp/calls")" -ge 2 ] \
  || fail "the drain did not remove the runner registered as the stop signal arrived: $(cat "$tmp/calls")"
set +m
ok "a runner registered as the stop signal arrives is seen by the drain"

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

echo "==> a headless host starts its own Colima VM"
ENGINE=colima runner run
[ "$rc" -eq 0 ] || fail "a colima run exited $rc: $(cat "$tmp/out")"
has 'colima start --vm-type vz --arch aarch64 --cpu 8 --memory 16 --disk 60' "a stopped VM starts native, with its disk size"
has 'docker run ' "colima run"
LINUX_RUNNER_VM_DISK=120 ENGINE=colima runner run
has '--disk 120' "LINUX_RUNNER_VM_DISK"
LINUX_RUNNER_VM_DISK=0 ENGINE=colima runner run
refused 'LINUX_RUNNER_VM_DISK must be a positive integer' "a zero disk"
FLAGS=colima-up ENGINE=colima runner run
lacks '^colima start' "a running VM"
ok "the VM is started when it is down, with --arch aarch64 and --disk, and left alone when it is up"
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
# What the installed wrapper passes: the retired settings, set to their off values.
QUEUE_SLOTS=0 CACHE_SEED=autumngarage/hesperus:swift-cache.yml KEEP_HOME=1 runner install-daemon "$real_user"
[ "$rc" -eq 0 ] || fail "install-daemon exited $rc: $(cat "$tmp/out")"
dplist="$tmp/daemons/com.autumngarage.linux-ephemeral-runner.plist"
[ -f "$dplist" ] || fail "install-daemon wrote no LaunchDaemon"
grep -Fq "<key>UserName</key><string>$real_user</string>" "$dplist" || fail "the daemon does not run as the fleet's user"
grep -Fq "<key>LINUX_RUNNER_ENGINE</key><string>colima</string>" "$dplist" || fail "the daemon does not use Colima"
grep -Fq "<key>LINUX_RUNNER_VM_DISK</key><string>60</string>" "$dplist" || fail "the daemon does not carry the VM's disk size"
grep -Fq "<key>LINUX_RUNNER_TOKEN_FILE</key><string>$user_state/github-token</string>" "$dplist" || fail "the daemon has no token file"
grep -Fq "<string>$user_state/linux-runner.sh</string>" "$dplist" || fail "the daemon does not run the installed copy"
grep -Fq "<key>HOME</key><string>$tmp/home</string>" "$dplist" || fail "the daemon's HOME is not the user's"
grep -Fq 'ghp_DAEMON' "$dplist" && fail "the token was written into the plist"
grep -Eq 'QUEUE_SLOTS|CACHE_SEED|LINUX_RUNNER_LABEL' "$dplist" && fail "the daemon carries a retired setting: $(cat "$dplist")"
[ -f "$user_state/linux-runner.sh" ] || fail "install-daemon did not copy the supervisor"
# The copy sources jit.sh from its own directory, so it must travel with it.
cmp -s "$user_state/jit.sh" "$root/runner/jit.sh" || fail "install-daemon did not copy runner/jit.sh beside the supervisor"
grep -Fq "<key>LINUX_RUNNER_LOG_FILE</key><string>$tmp/home/Library/Logs/linux-ephemeral-runner.log</string>" "$dplist" \
  || fail "the daemon does not name the log run reopens: $(grep -A1 LOG_FILE "$dplist")"
grep -Fq "<key>StandardOutPath</key><string>$tmp/home/Library/Logs/linux-ephemeral-runner.log</string>" "$dplist" \
  && fail "launchd holds the rotated log open, so rotation would strand the daemon's writes"
grep -Fq '<key>ExitTimeOut</key><integer>5400</integer>' "$dplist" || fail "the daemon is not given time to drain before the service manager kills it"
has 'launchctl bootstrap system' "install-daemon"
has "chown $real_user:$real_group $user_state/linux-runner.sh $user_state/jit.sh" "the installed copies belong to the fleet's user"
ok "the LaunchDaemon runs a copy as the fleet's user, on Colima, with its private token and no retired setting"
rule="$tmp/newsyslog/linux-ephemeral-runner.conf"
expected_rule="$tmp/home/Library/Logs/linux-ephemeral-runner.log $real_user:staff 644 5 10240 * NJ"
[ "$(cat "$rule" 2>/dev/null)" = "$expected_rule" ] || fail "the newsyslog rule is not the owner's: $(cat "$rule" 2>/dev/null)"
has "chown root:wheel $rule" "the newsyslog rule belongs to root"
rule_mode="$(stat -c %a "$rule" 2>/dev/null || stat -f %Lp "$rule")"
[ "$rule_mode" = 644 ] || fail "the newsyslog rule is mode $rule_mode"
# The owner installed this rule by hand: installing again leaves it as it was.
seed_token
KEEP_DAEMONS=1 KEEP_HOME=1 runner install-daemon "$real_user"
[ "$rc" -eq 0 ] || fail "a second install-daemon exited $rc: $(cat "$tmp/out")"
[ "$(cat "$rule")" = "$expected_rule" ] || fail "a second install changed the newsyslog rule: $(cat "$rule")"
ok "install-daemon writes the newsyslog rule for the daemon's log, idempotently"
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
[ ! -f "$dplist" ] || fail "a refused install left a LaunchDaemon"
[ ! -f "$rule" ] || fail "a refused install left a newsyslog rule"
ok "install-daemon refuses without root, a real user, or that user's private token"
runner install
[ "$rc" -eq 2 ] || fail "the retired login-session install still ran (exit $rc): $(cat "$tmp/out")"
ok "the login-session LaunchAgent is gone; the fleet runs only as a LaunchDaemon"

echo "==> replacing a running fleet never leaves it stopped without saying how to start it"
# launchd is still ending the old service when bootout returns, and a load in
# that window fails with the old one already gone (AUT-2258 on the macOS
# pool, AUT-2275 here). The install waits for it to leave and tries the load
# again, through the one replace_service in jit.sh.
seed_token
FLAGS=service-lingers KEEP_HOME=1 runner install-daemon "$real_user"
[ "$rc" -eq 0 ] || fail "install-daemon over a daemon that was still leaving exited $rc: $(cat "$tmp/out")"
[ "$(line_of 'sleep 1')" -lt "$(line_of 'launchctl bootstrap system')" ] || fail "the new daemon was loaded before the old one had left: $(cat "$tmp/calls")"
seed_token
FLAGS=service-busy KEEP_HOME=1 runner install-daemon "$real_user"
[ "$rc" -eq 0 ] || fail "install-daemon gave up on a load launchd refused twice: $(cat "$tmp/out")"
[ "$(grep -c 'launchctl bootstrap system' "$tmp/calls")" -eq 3 ] || fail "expected the load to be tried three times: $(grep 'bootstrap system' "$tmp/calls")"
# A load that never succeeds is given up on after the wait, and the message
# is the command that starts the fleet, because the old daemon is gone.
seed_token
FLAGS=service-stuck KEEP_HOME=1 runner install-daemon "$real_user"
refused "sudo launchctl bootstrap system '$dplist'" "a daemon launchd will not load"
grep -q 'the old service is stopped and the fleet is not running' "$tmp/out" || fail "the refusal did not say the fleet is stopped: $(cat "$tmp/out")"
grep -q 'Input/output error' "$tmp/out" || fail "the refusal did not carry launchd's reason: $(cat "$tmp/out")"
# An old daemon that outlives the wait is still the service launchd lists, so
# finding one there is not the new daemon loaded: the install fails, having
# tried no load, and names the command for when the old one has gone.
seed_token
FLAGS=service-stays KEEP_HOME=1 runner install-daemon "$real_user"
refused "sudo launchctl bootstrap system '$dplist'" "an install over a daemon that never left"
grep -q 'was still in launchd 60s after its bootout' "$tmp/out" || fail "the refusal did not say the old daemon was still there: $(cat "$tmp/out")"
lacks 'launchctl bootstrap system' "an install over a daemon that never left"
grep -q 'installed com.autumngarage.linux-ephemeral-runner' "$tmp/out" && fail "an install over a daemon that never left reported success: $(cat "$tmp/out")"
ok "the install waits for the daemon it replaces, retries the load, and names the command if it cannot"
seed_token
KEEP_HOME=1 runner install-daemon "$real_user"
[ -f "$dplist" ] && [ -f "$rule" ] || fail "install-daemon left nothing to uninstall"
KEEP_DAEMONS=1 runner uninstall-daemon
[ "$rc" -eq 0 ] || fail "uninstall-daemon exited $rc"
has 'launchctl bootout system/com.autumngarage.linux-ephemeral-runner' "uninstall-daemon"
[ ! -e "$dplist" ] || fail "uninstall-daemon left the LaunchDaemon"
[ ! -e "$rule" ] || fail "uninstall-daemon left the newsyslog rule"
ok "uninstall-daemon boots the daemon out and removes its plist and log rotation"

echo "==> the log survives rotation: run reopens it for every line"
log_path="$tmp/logs/fleet.log"
rm -rf "$tmp/logs"; mkdir -p "$tmp/logs"
LOG_FILE="$log_path" FLAGS=rotate-log runner run
[ "$rc" -eq 0 ] || fail "a run with a log file exited $rc: $(cat "$tmp/out")"
[ ! -s "$tmp/out" ] || fail "run wrote to stdout instead of its log: $(cat "$tmp/out")"
[ -f "$log_path.0" ] || fail "the fake did not rotate the log"
grep -q 'supervising' "$log_path.0" || fail "the rotated log lacks the lines before rotation: $(cat "$log_path.0")"
[ -s "$log_path" ] || fail "nothing reached the log after rotation; the supervisor kept writing to the renamed file"
ok "after newsyslog renames the log, the next line starts a new one at the same path"

echo "runner supervisor passed"

# AUT-2593: the base installs a pinned, signature-verified toolchain, not a
# floating executable that can stop working under the fleet's x64 emulator.
# The Docker build additionally compiles and executes as its nonroot runner.
python3 - "$root/runner/Dockerfile" <<'PY'
from pathlib import Path
import re
import sys
source = Path(sys.argv[1]).read_text()
assert 'swiftly init' not in source and 'download.swift.org/swiftly' not in source
assert re.search(r'ARG SWIFT_VERSION=\d+\.\d+\.\d+\n', source)
assert re.search(r'ARG SWIFT_SIGNING_KEY=[A-F0-9]{40}\n', source)
install = source[source.index('ARG SWIFT_SIGNING_KEY='):]
assert "amd64) suffix=''" in install and "arm64) suffix='-aarch64'" in install
assert '*) echo \'unsupported Swift architecture\' >&2; exit 1' in install
assert install.index('gpg --batch --verify') < install.index('tar -xzf')
assert 'ENV PATH=/opt/swift/usr/bin:$PATH\nUSER runner' in install
assert 'swiftc "$probe/main.swift" -o "$probe/probe"' in install
assert 'test "$("$probe/probe")" = \'runner Swift works\'' in install
PY
ok 'Swift source is pinned and verified before extraction; the nonroot build compiles and runs it'
