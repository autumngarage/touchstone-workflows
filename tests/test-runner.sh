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
    if [ -f "$FAKE_STATE/seed-only-group" ]; then echo "autumngarage/hesperus true"; exit 0; fi
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
  # What waits for a runner (AUT-2757). runs-fail: GitHub cannot say.
  # queued-run is set with queued-jobs, whose lines are what the real jq would
  # print for each queued job of the fleet: "queue" for a merge-queue job,
  # "pr" for any other. runner-busy is what a runner reports as .busy.
  *"actions/runs?status=queued"*)
    [ ! -f "$FAKE_STATE/runs-fail" ] || exit 1
    [ -f "$FAKE_STATE/queued-run" ] && echo 101
    exit 0
    ;;
  *"repos/autumngarage/vesper/actions/runs/101/jobs"*)
    cat "$FAKE_STATE/queued-jobs" 2>/dev/null
    exit 0
    ;;
  *"orgs/autumngarage/actions/runners/"*"--jq .busy"*)
    cat "$FAKE_STATE/runner-busy" 2>/dev/null || echo false
    exit 0
    ;;
  # The cache seed's record (AUT-2672): seed-run is a recent push run of the
  # seed workflow; seed-job-ok says that run has a successful job on the
  # runner the query names. The real jq does the selecting; this answers as
  # it would.
  *"repos/autumngarage/hesperus --jq .default_branch"*) echo main ;;
  *"actions/workflows/swift-cache.yml/runs?branch=main&event=push"*)
    [ -f "$FAKE_STATE/seed-run" ] && echo "77 ${FAKE_SEED_STARTED:-2026-10-20T10:00:00Z}"
    exit 0
    ;;
  *"actions/runs/77/jobs"*)
    [ -f "$FAKE_STATE/seed-job-ok" ] && echo 555
    exit 0
    ;;
esac
EOF
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$FAKE_CALLS"
case "$1" in
  image)
    [ ! -f "$FAKE_STATE/no-image" ] || exit 1
    [ "$2" = inspect ] || exit 0
    # The base image's id; the cache image exists once commit made it.
    case "$*" in
      *-swift-cache*)
        [ -f "$FAKE_STATE/cache-image" ] || exit 1
        case "$*" in
          *swift-cache.base*) cat "$FAKE_STATE/cache-base" ;;
          *seed-started*) cat "$FAKE_STATE/cache-started" ;;
        esac
        ;;
      *'{{.Id}}'*) cat "$FAKE_STATE/base-id" 2>/dev/null || echo sha256:base-1 ;;
    esac
    ;;
  run)
    # What the container reads on stdin, where the configuration must arrive.
    case " $* " in *" -i "*) printf 'docker-stdin %s\n' "$(cat)" >>"$FAKE_CALLS" ;; esac
    # A real runner waits for its job; HOLD says for how long.
    /bin/sleep "${FAKE_DOCKER_HOLD:-0}"
    exit "${FAKE_DOCKER_RC:-0}"
    ;;
  # Only the seed's validation writes the key file.
  cp)
    [ "$2" != -a ] || shift
    case "$2" in *:/home/runner/.touchstone-swift-cache-key) [ -f "$FAKE_STATE/seed-key" ] || exit 1 ;; esac
    [ "$3" != - ] || echo tar
    case "$2" in *.build) [ ! -f "$FAKE_STATE/cp-fails" ] || exit 1 ;; esac
    [ "$2" != - ] || cat >/dev/null
    ;;
  commit)
    [ ! -f "$FAKE_STATE/commit-fails" ] || exit 1
    for arg in "$@"; do
      case "$arg" in
        "LABEL touchstone.swift-cache.base="*) printf '%s\n' "${arg#*=}" >"$FAKE_STATE/cache-base" ;;
        "LABEL touchstone.swift-cache.seed-started="*) printf '%s\n' "${arg#*=}" >"$FAKE_STATE/cache-started" ;;
      esac
    done
    touch "$FAKE_STATE/cache-image"
    ;;
  ps) cat "$FAKE_STATE/leftovers" 2>/dev/null || true ;;
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
# state; stdout+stderr land in $tmp/out and the exit code in $rc. KEEP_FAKE
# keeps the fake engine's images from the previous call.
runner() {
  rm -rf "${tmp:?}/state" "${tmp:?}/daemons"
  [ -n "${KEEP_FAKE:-}" ] || rm -rf "${tmp:?}/fake"
  [ -n "${KEEP_HOME:-}" ] || rm -rf "${tmp:?}/home"
  mkdir -p "$tmp/state" "$tmp/fake" "$tmp/home"
  : >"$tmp/calls"
  for flag in ${FLAGS:-}; do touch "$tmp/fake/$flag"; done
  if [ -n "${QUEUED_JOBS:-}" ]; then
    touch "$tmp/fake/queued-run"
    printf '%b' "$QUEUED_JOBS" >"$tmp/fake/queued-jobs"
  fi
  [ -z "${BUSY:-}" ] || printf '%s\n' "$BUSY" >"$tmp/fake/runner-busy"
  set +e
  PATH="$bin:$PATH" HOME="$tmp/home" FAKE_CALLS="$tmp/calls" FAKE_STATE="$tmp/fake" \
    LINUX_RUNNER_STATE_DIR="$tmp/state" LINUX_RUNNER_SLOTS="${SLOTS:-1}" \
    LINUX_RUNNER_QUEUE_SLOTS="${QUEUE_SLOTS:-}" \
    LINUX_RUNNER_MAX_JOBS="${JOBS:-1}" FAKE_DOCKER_RC="${DOCKER_RC:-0}" \
    LINUX_RUNNER_ENGINE="${ENGINE:-docker}" LINUX_RUNNER_TOKEN_FILE="${TOKEN_FILE:-}" \
    LINUX_RUNNER_DAEMON_DIR="$tmp/daemons" FAKE_HOME="$tmp/home" FAKE_DOCKER_HOLD="${HOLD:-0}" \
    LINUX_RUNNER_CACHE_SEED="${CACHE_SEED:-}" FAKE_SEED_STARTED="${SEED_STARTED:-}" \
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
# With no slot reserved, every slot takes every job, as before AUT-2704.
has 'labels[]=linux-ephemeral-shared' "an unreserved slot carries the label validate requires outside the merge queue"
run_line="$(grep '^docker run ' "$tmp/calls")"
# --pids-limit keeps a pull request that forks without end inside its own
# container instead of exhausting the VM every slot shares.
# The last literal is the container's own command text, matched as written.
# shellcheck disable=SC2016
for arg in '--init' ' -i ' '--memory 6g' '--cpus 4' '--pids-limit 4096' '--pull never' 'exec ./run.sh --jitconfig "$jit"'; do
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
lacks 'docker cp|docker commit|actions/workflows' "with no cache seed configured, a finished container is only removed"
[ -z "$(ls "$tmp/state")" ] || fail "a finished slot left state behind: $(ls "$tmp/state")"
ok "the registration is forgotten and the slot's state removed after the job"

echo "==> a slot kept ready for the merge queue takes only its jobs (AUT-2704)"
SLOTS=3 QUEUE_SLOTS=1 runner run
[ "$rc" -eq 0 ] || fail "a run with a reserved slot exited $rc: $(cat "$tmp/out")"
registrations() { grep 'generate-jitconfig' "$tmp/calls" | grep -F -- "name=linux-ephemeral-testhost-$1-" || true; }
for slot in 1 2 3; do
  [ "$(registrations "$slot" | grep -c .)" -eq 1 ] || fail "slot $slot did not register exactly once: $(cat "$tmp/calls")"
  registrations "$slot" | grep -Fq 'labels[]=self-hosted -f labels[]=linux-ephemeral' || fail "slot $slot lost its required labels: $(registrations "$slot")"
done
registrations 1 | grep -Fq 'linux-ephemeral-shared' && fail "the reserved slot carries the shared label: $(registrations 1)"
for slot in 2 3; do
  registrations "$slot" | grep -Fq 'labels[]=linux-ephemeral-shared' || fail "unreserved slot $slot lacks the shared label: $(registrations "$slot")"
done
grep -Fq 'supervising 3 slot(s), 1 kept ready for the merge queue' "$tmp/out" || fail "the reservation is not logged: $(cat "$tmp/out")"
ok "with nothing waiting, the first QUEUE_SLOTS slots lack the shared label; the others carry it"

echo "==> a runner's role follows what is waiting for a runner (AUT-2757)"
# queue_only: how many registrations lack the shared label (queue-only).
registered() { grep -c 'generate-jitconfig' "$tmp/calls" || true; }
queue_only() { grep 'generate-jitconfig' "$tmp/calls" | grep -vc 'linux-ephemeral-shared' || true; }
# Which slot registers first varies, so each case holds for any order.
# A pull request waits and the queue is idle: no slot sits ready for the queue.
HOLD=4 SLOTS=3 QUEUE_SLOTS=1 QUEUED_JOBS='pr\n' runner run
[ "$rc" -eq 0 ] || fail "a run with a pull request waiting exited $rc: $(cat "$tmp/out")"
[ "$(registered)" -eq 3 ] && [ "$(queue_only)" -eq 0 ] \
  || fail "a waiting pull request left a slot idle for the queue: $(grep generate-jitconfig "$tmp/calls")"
ok "while a pull request waits and no queue job does, the reserved slot takes pull requests too"
# One queue job and one pull request wait: exactly one runner answers the queue.
HOLD=4 SLOTS=2 QUEUE_SLOTS=1 QUEUED_JOBS='queue\npr\n' runner run
[ "$(registered)" -eq 2 ] && [ "$(queue_only)" -eq 1 ] \
  || fail "one waiting queue job did not get exactly one queue-only runner: $(grep generate-jitconfig "$tmp/calls")"
ok "one waiting queue job gets one queue-only runner, however the slots race"
# Two queue jobs and a pull request wait: two runners answer the queue.
HOLD=4 SLOTS=3 QUEUE_SLOTS=1 QUEUED_JOBS='queue\nqueue\npr\n' runner run
[ "$(registered)" -eq 3 ] && [ "$(queue_only)" -eq 2 ] \
  || fail "two waiting queue jobs did not get two queue-only runners: $(grep generate-jitconfig "$tmp/calls")"
ok "queue jobs outrank pull requests for freed slots, up to the number that wait"
# A queue-only runner that is busy answers nothing that waits.
HOLD=4 SLOTS=2 QUEUE_SLOTS=1 BUSY=true QUEUED_JOBS='queue\npr\n' runner run
[ "$(registered)" -eq 2 ] && [ "$(queue_only)" -eq 2 ] \
  || fail "a busy queue-only runner was counted as waiting for the queue job: $(grep generate-jitconfig "$tmp/calls")"
ok "only an idle queue-only runner answers a waiting queue job, on GitHub's word"
# GitHub cannot say what waits: the fixed reservation.
SLOTS=3 QUEUE_SLOTS=1 FLAGS=runs-fail runner run
[ "$rc" -eq 0 ] || fail "a run that could not read the waiting jobs exited $rc: $(cat "$tmp/out")"
grep -Fq 'using the fixed reservation' "$tmp/out" || fail "the fallback is not logged: $(cat "$tmp/out")"
[ "$(registered)" -eq 3 ] && [ "$(queue_only)" -eq 1 ] \
  || fail "the fixed reservation was not used: $(grep generate-jitconfig "$tmp/calls")"
ok "without GitHub's answer, the first QUEUE_SLOTS slots are queue-only"
# Off: no reservation and no look at what waits.
SLOTS=3 QUEUED_JOBS='queue\n' runner run
[ "$(queue_only)" -eq 0 ] || fail "a runner was queue-only with QUEUE_SLOTS unset: $(grep generate-jitconfig "$tmp/calls")"
lacks 'actions/runs\?status=queued' "QUEUE_SLOTS unset"
ok "with QUEUE_SLOTS unset every runner is shared and nothing waiting is read"
for bad in 3 4 x; do
  SLOTS=3 QUEUE_SLOTS=$bad runner run
  [ "$rc" -ne 0 ] || fail "QUEUE_SLOTS=$bad of 3 was accepted"
  lacks 'generate-jitconfig' "QUEUE_SLOTS=$bad"
done
grep -Fq 'LINUX_RUNNER_QUEUE_SLOTS must be a non-negative integer' "$tmp/out" || fail "a malformed reservation was not named: $(cat "$tmp/out")"
ok "a reservation that would leave pull requests no slot, or is not a number, registers nothing"

echo "==> the cache seed's products are kept only on GitHub's word (AUT-2672)"
seed=autumngarage/hesperus:swift-cache.yml
# A job that left no key: nothing asked, nothing kept, the container removed.
CACHE_SEED=$seed runner run
[ "$rc" -eq 0 ] || fail "a cache-seed run exited $rc: $(cat "$tmp/out")"
lacks 'actions/workflows|docker commit' "a job with no cache key"
has 'docker rm -f linux-ephemeral-testhost-1-' "a job with no cache key"
run_line="$(grep '^docker run ' "$tmp/calls")"
case "$run_line" in *"linux-ephemeral-runner:local bash -c"*) ;; *) fail "with no cache image, a job must start from the base: $run_line" ;; esac
# A key in the container is the job's own claim. A pull request's job can
# write one too, so without GitHub's record of the seed nothing is kept.
for flags in 'seed-key' 'seed-key seed-run'; do
  FLAGS=$flags CACHE_SEED=$seed runner run
  [ "$rc" -eq 0 ] || fail "$flags: exited $rc: $(cat "$tmp/out")"
  has 'actions/workflows/swift-cache.yml/runs?branch=main&event=push' "$flags: GitHub is asked for the seed's default-branch push runs"
  case "$flags" in *seed-run*) has 'select(.runner_name == "linux-ephemeral-testhost-1-' "$flags: and for a job on this very runner" ;; esac
  lacks 'docker commit' "$flags: a job GitHub does not record as the seed"
  grep -q 'GitHub records no successful autumngarage/hesperus:swift-cache.yml job' "$tmp/out" || fail "$flags: the refusal is not logged: $(cat "$tmp/out")"
  has 'docker rm -f linux-ephemeral-testhost-1-' "$flags: an unproven container is removed"
done
ok "a container's own claim to be the seed keeps nothing"
FLAGS='seed-key seed-run seed-job-ok' CACHE_SEED=$seed runner run
[ "$rc" -eq 0 ] || fail "a seed run exited $rc: $(cat "$tmp/out")"
has 'docker cp -a linux-ephemeral-testhost-1-' "the seed's .build is copied"
has ':/home/runner/_work/hesperus/hesperus/.build -' "from the seed's workspace"
has ':/home/runner/swift-build-cache/autumngarage/hesperus' "into the cache path validate.yml reads"
has 'docker commit --change LABEL touchstone.swift-cache.base=sha256:base-1 --change LABEL touchstone.swift-cache.seed-started=2026-10-20T10:00:00Z' "the cache image records its base and its seed"
has 'linux-ephemeral-runner:local-swift-cache' "the cache image's tag"
[ "$(grep -c '^docker rm -f linux-ephemeral-testhost-1-' "$tmp/calls")" -ge 2 ] || fail "the seed's and the staging containers are not both removed: $(cat "$tmp/calls")"
[ -z "$(ls "$tmp/state")" ] || fail "keeping the cache left state behind: $(ls "$tmp/state")"
ok "a job GitHub records as the seed's success leaves its products in the cache image"
# The cache image holds the seed repository's build, so a group that admits
# any other repository never starts a job from it.
KEEP_FAKE=1 CACHE_SEED=$seed runner run
case "$(grep '^docker run ' "$tmp/calls")" in *"linux-ephemeral-runner:local bash -c"*) ;; *) fail "a group shared with another repository started a job from the cache image: $(grep '^docker run ' "$tmp/calls")" ;; esac
grep -q "admits repositories other than autumngarage/hesperus; this job starts without its build cache" "$tmp/out" || fail "the shared group is not logged: $(cat "$tmp/out")"
ok "a runner group shared with another repository never starts a job from the cache image"
# The next job starts from the cache image, while it was made from this base.
FLAGS=seed-only-group KEEP_FAKE=1 CACHE_SEED=$seed runner run
case "$(grep '^docker run ' "$tmp/calls")" in *"linux-ephemeral-runner:local-swift-cache bash -c"*) ;; *) fail "the next job did not start from the cache image: $(grep '^docker run ' "$tmp/calls")" ;; esac
echo sha256:base-2 >"$tmp/fake/base-id"
FLAGS=seed-only-group KEEP_FAKE=1 CACHE_SEED=$seed runner run
case "$(grep '^docker run ' "$tmp/calls")" in *"linux-ephemeral-runner:local bash -c"*) ;; *) fail "a rebuilt base kept the old products: $(grep '^docker run ' "$tmp/calls")" ;; esac
ok "jobs start from the cache image only while its base is the base image as it is"
# An older seed that finishes last does not replace a newer one's products.
# (The run above found the seed's flags still set, so its cache image is now
# made from base-2, by the same seed.)
touch "$tmp/fake/seed-key" "$tmp/fake/seed-run" "$tmp/fake/seed-job-ok"
SEED_STARTED=2026-10-20T09:00:00Z KEEP_FAKE=1 CACHE_SEED=$seed runner run
lacks 'docker commit' "an older seed"
grep -q 'already holds one started 2026-10-20T10:00:00Z' "$tmp/out" || fail "the older seed's refusal is not logged: $(cat "$tmp/out")"
SEED_STARTED=2026-10-20T11:00:00Z KEEP_FAKE=1 CACHE_SEED=$seed runner run
has 'touchstone.swift-cache.seed-started=2026-10-20T11:00:00Z' "a newer seed"
ok "a newer seed replaces the products; an older one does not"
FLAGS='seed-key seed-run seed-job-ok cp-fails' CACHE_SEED=$seed runner run
[ "$rc" -eq 0 ] || fail "a failed copy stopped the slot: $(cat "$tmp/out")"
lacks 'docker commit' "a failed copy"
grep -q "jobs keep the previous ones" "$tmp/out" || fail "a failed copy is not logged: $(cat "$tmp/out")"
ok "a copy that fails keeps nothing, says so, and the slot goes on"
# What a killed supervisor left is cleared when the next one starts.
mkdir -p "$tmp/fake"
FLAGS='' runner run
printf 'abc123\n' >"$tmp/fake/leftovers"
KEEP_FAKE=1 runner run
has 'docker ps -aq --filter name=^linux-ephemeral-testhost-' "leftovers are looked for"
has 'docker rm -f abc123' "a leftover container is removed"
ok "a restart removes the containers a killed supervisor left"

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
CACHE_SEED=hesperus runner run
refused 'LINUX_RUNNER_CACHE_SEED must be OWNER/REPO:WORKFLOW_FILE' "a malformed cache seed"
lacks 'generate-jitconfig' "a malformed cache seed"
ok "a malformed cache seed registers nothing"

echo "==> install runs the supervisor from a copy, kept awake"
runner install
[ "$rc" -eq 0 ] || fail "install exited $rc: $(cat "$tmp/out")"
plist="$tmp/home/Library/LaunchAgents/com.autumngarage.linux-ephemeral-runner.plist"
[ -f "$plist" ] || fail "install wrote no LaunchAgent"
grep -Fq '<string>/usr/bin/caffeinate</string>' "$plist" || fail "the agent is not kept awake"
grep -Fq "<string>$tmp/state/linux-runner.sh</string>" "$plist" || fail "the agent does not run the installed copy"
[ -f "$tmp/state/linux-runner.sh" ] || fail "install did not copy the supervisor"
# The copy sources jit.sh from its own directory, so it must travel with it.
cmp -s "$tmp/state/jit.sh" "$root/runner/jit.sh" || fail "install did not copy runner/jit.sh beside the supervisor"
grep -Fq '<key>LINUX_RUNNER_LABEL</key><string>linux-ephemeral</string>' "$plist" || fail "the agent lost its label"
grep -Fq '<key>LINUX_RUNNER_QUEUE_SLOTS</key><string>0</string>' "$plist" || fail "the agent lost its merge-queue reservation"
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
cmp -s "$user_state/jit.sh" "$root/runner/jit.sh" || fail "install-daemon did not copy runner/jit.sh beside the supervisor"
has 'launchctl bootstrap system' "install-daemon"
has "chown $real_user:$real_group $user_state/linux-runner.sh $user_state/jit.sh" "the installed copies belong to the fleet's user"
ok "the LaunchDaemon runs a copy as the fleet's user, on Colima, with its private token"
seed_token
CACHE_SEED=autumngarage/hesperus:swift-cache.yml KEEP_HOME=1 runner install-daemon "$real_user"
grep -Fq "<key>LINUX_RUNNER_CACHE_SEED</key><string>autumngarage/hesperus:swift-cache.yml</string>" "$dplist" || fail "the daemon lost its cache seed"
ok "the LaunchDaemon carries the cache seed"
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

echo "==> replacing a running fleet never leaves it stopped without saying how to start it"
# launchd is still ending the old service when bootout returns, and a load in
# that window fails with the old one already gone (AUT-2258 on the macOS
# pool, AUT-2275 here). Both installs wait for it to leave and try the load
# again, through the one replace_service in jit.sh.
line_of() { grep -nF -- "$1" "$tmp/calls" | head -1 | cut -d: -f1; }
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
# The login-session agent is replaced the same way, in its own domain and
# with no sudo in the command it names.
FLAGS=service-lingers runner install
[ "$rc" -eq 0 ] || fail "install over an agent that was still leaving exited $rc: $(cat "$tmp/out")"
[ "$(line_of 'sleep 1')" -lt "$(line_of 'launchctl bootstrap gui/')" ] || fail "the new agent was loaded before the old one had left: $(cat "$tmp/calls")"
FLAGS=service-stuck runner install
refused "Load it with: launchctl bootstrap gui/" "an agent launchd will not load"
ok "both installs wait for the service they replace, retry the load, and name the command if they cannot"
runner uninstall-daemon
[ "$rc" -eq 0 ] || fail "uninstall-daemon exited $rc"
has 'launchctl bootout system/com.autumngarage.linux-ephemeral-runner' "uninstall-daemon"
ok "uninstall-daemon boots the daemon out"

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
