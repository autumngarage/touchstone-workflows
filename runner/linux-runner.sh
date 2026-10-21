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
# socket, no host network, no credential. Nothing a job does reaches another
# job, which is what lets `validate` -- it runs the candidate's declared
# commands -- use these runners at all (see "Runner" in README.md).
#
# One exception, and only for code that has merged: with LINUX_RUNNER_CACHE_SEED
# set, the build products of that repository's cache seed are kept in a job
# image derived from the base one, so later jobs copy them instead of
# downloading the same products from GitHub's cache (AUT-2672). They are kept
# only when GitHub, not the container, says the finished runner ran that
# workflow's job for a push to the default branch and the job succeeded. Every
# job still starts in a fresh container of an image no job can write.
#
# Configuration, from the environment (defaults in parentheses):
#   LINUX_RUNNER_ORG      organization (autumngarage)
#   LINUX_RUNNER_GROUP    runner group, restricted to the private consumers (linux-ephemeral)
#   LINUX_RUNNER_LABEL    the label the LINUX_RUNNER variable names (linux-ephemeral)
#   LINUX_RUNNER_SLOTS    jobs run at once (2)
#   LINUX_RUNNER_QUEUE_SLOTS  how many of those slots only merge-queue jobs
#                         may take (0). Every other slot also carries the label
#                         LABEL-shared, which validate.yml requires for every
#                         event but merge_group; a freed runner otherwise goes
#                         to whichever job GitHub picks, often a pull request
#                         queued after the queue's (AUT-2704). Must be fewer
#                         than LINUX_RUNNER_SLOTS
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
#   LINUX_RUNNER_CACHE_SEED  OWNER/REPO:WORKFLOW_FILE, the workflow whose
#                         default-branch push runs seed that repository's
#                         Swift build cache, e.g.
#                         autumngarage/hesperus:swift-cache.yml (unset: off).
#                         The token then also needs Actions read access to
#                         that repository. Jobs start from the cache image
#                         only while the runner group admits that repository
#                         and no other.
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
QUEUE_SLOTS="${LINUX_RUNNER_QUEUE_SLOTS:-0}"
MEMORY="${LINUX_RUNNER_MEMORY:-6g}"
CPUS="${LINUX_RUNNER_CPUS:-4}"
PIDS="${LINUX_RUNNER_PIDS:-4096}"
IMAGE="${LINUX_RUNNER_IMAGE:-linux-ephemeral-runner:local}"
ENGINE="${LINUX_RUNNER_ENGINE:-docker}"
VM_CPUS="${LINUX_RUNNER_VM_CPUS:-8}"
VM_MEMORY="${LINUX_RUNNER_VM_MEMORY:-16}"
TOKEN_FILE="${LINUX_RUNNER_TOKEN_FILE:-}"
CACHE_SEED="${LINUX_RUNNER_CACHE_SEED:-}"
CACHE_IMAGE="$IMAGE-swift-cache"
# Where validate.yml looks for them, and where its seed leaves its cache key.
CACHE_ROOT=/home/runner/swift-build-cache
CACHE_KEY_FILE=/home/runner/.touchstone-swift-cache-key
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
case "$QUEUE_SLOTS" in '' | *[!0-9]*) die "LINUX_RUNNER_QUEUE_SLOTS must be a non-negative integer, not '$QUEUE_SLOTS'" ;; esac
[ "$QUEUE_SLOTS" -lt "$SLOTS" ] || die "LINUX_RUNNER_QUEUE_SLOTS ($QUEUE_SLOTS) must be fewer than LINUX_RUNNER_SLOTS ($SLOTS), or no pull request could run"
case "$MAX_JOBS" in *[!0-9]*) die "LINUX_RUNNER_MAX_JOBS must be a non-negative integer, not '$MAX_JOBS'" ;; esac
case "$PIDS" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_PIDS must be a positive integer, not '$PIDS'" ;; esac
case "$ENGINE" in docker | colima) ;; *) die "LINUX_RUNNER_ENGINE must be docker or colima, not '$ENGINE'" ;; esac
case "$CACHE_SEED" in '' | */*:*.yml | */*:*.yaml) ;; *) die "LINUX_RUNNER_CACHE_SEED must be OWNER/REPO:WORKFLOW_FILE, not '$CACHE_SEED'" ;; esac

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

# Whether runner group GID admits the cache seed's repository and no other.
# The cache image holds that repository's build: a job of any other
# repository the group admits must never start from it.
group_is_seed_only() {
  local repos
  repos="$(gh api --paginate "orgs/$ORG/actions/runner-groups/$1/repositories" \
    --jq '.repositories[] | "\(.full_name) \(.private)"')" || return 1
  [ "$repos" = "${CACHE_SEED%%:*} true" ]
}

# The image a job starts from: the cache image when it was made from the base
# image as it is now, otherwise the base. A rebuilt base drops the products.
job_image() {
  local base made_from
  if [ -n "$CACHE_SEED" ] \
    && base="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)" \
    && made_from="$(docker image inspect -f '{{index .Config.Labels "touchstone.swift-cache.base"}}' "$CACHE_IMAGE" 2>/dev/null)" \
    && [ "$made_from" = "$base" ]; then
    printf '%s\n' "$CACHE_IMAGE"
  else
    printf '%s\n' "$IMAGE"
  fi
}

# seed_run NAME: print the start time of the cache seed's run whose job ran on
# runner NAME and succeeded, for a push to the repository's default branch.
# GitHub's record is the only evidence: the container's files are the job's
# own and prove nothing. The job's conclusion can reach the API a moment
# after its runner exits, so ask again before giving up.
seed_run() {
  local name="$1" repo="${CACHE_SEED%%:*}" workflow="${CACHE_SEED#*:}" branch run started tries=0
  branch="$(gh api "repos/$repo" --jq .default_branch)" || return 1
  while [ "$tries" -lt 3 ]; do
    while read -r run started; do
      [ -n "$run" ] || continue
      if gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" \
        --jq ".jobs[] | select(.runner_name == \"$name\" and .conclusion == \"success\") | .id" | grep -q .; then
        printf '%s\n' "$started"
        return 0
      fi
    done <<EOF
$(gh api "repos/$repo/actions/workflows/$workflow/runs?branch=$branch&event=push&per_page=5" \
      --jq ".workflow_runs[] | select(.head_branch == \"$branch\" and .head_repository.full_name == \"$repo\") | \"\\(.id) \\(.run_started_at)\"")
EOF
    tries=$((tries + 1))
    sleep 10
  done
  return 1
}

# keep_cache NAME: after runner NAME's container has exited, keep its .build
# in the cache image if that job was the cache seed, then remove the
# container. Runs beside the slot, so the next job does not wait for it; one
# at a time, and an older seed never replaces a newer one's products.
keep_cache() {
  local name="$1" repo="${CACHE_SEED%%:*}" src started base kept staging lock="$state_dir/keep-cache.lock"
  src="/home/runner/_work/${repo#*/}/${repo#*/}/.build"
  # Only the seed writes the key file, so most jobs stop here without asking
  # GitHub anything.
  if docker cp "$name:$CACHE_KEY_FILE" - >/dev/null 2>&1; then
    if ! started="$(seed_run "$name")"; then
      log "$name left a cache key, but GitHub records no successful $CACHE_SEED job on it; nothing kept"
    else
      until mkdir "$lock" 2>/dev/null; do sleep 5; done
      kept="$(docker image inspect -f '{{index .Config.Labels "touchstone.swift-cache.seed-started"}}' "$CACHE_IMAGE" 2>/dev/null || true)"
      base="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
      staging="$name-cache"
      if [ -n "$kept" ] && [ "$(job_image)" = "$CACHE_IMAGE" ] && ! [ "$kept" \< "$started" ]; then
        log "$name ran the $CACHE_SEED seed started $started; $CACHE_IMAGE already holds one started $kept"
      elif [ -n "$base" ] \
        && docker run --name "$staging" --pull never "$IMAGE" mkdir -p "$CACHE_ROOT/$repo" >/dev/null \
        && docker cp -a "$name:$src" - | docker cp -a - "$staging:$CACHE_ROOT/$repo" \
        && docker cp -a "$name:$CACHE_KEY_FILE" - | docker cp -a - "$staging:$CACHE_ROOT/$repo" \
        && docker commit \
          --change "LABEL touchstone.swift-cache.base=$base" \
          --change "LABEL touchstone.swift-cache.seed-started=$started" \
          "$staging" "$CACHE_IMAGE" >/dev/null; then
        log "kept the build products of the $CACHE_SEED seed started $started (runner $name) in $CACHE_IMAGE"
        docker image prune -f --filter "label=touchstone.swift-cache.base" >/dev/null 2>&1 || true
      else
        log "could not keep the build products of the $CACHE_SEED seed on $name; jobs keep the previous ones"
      fi
      docker rm -f "$staging" >/dev/null 2>&1 || true
      rmdir "$lock"
    fi
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
}

run_slot() {
  local slot="$1" backoff="$BACKOFF_START" jobs=0
  local gid name response jit id started rc image shared=""
  # Slots 1..QUEUE_SLOTS are the merge queue's; only the others take the jobs
  # that require LABEL-shared.
  [ "$slot" -le "$QUEUE_SLOTS" ] || shared="$LABEL-shared"
  while :; do
    if [ -n "$MAX_JOBS" ] && [ "$jobs" -ge "$MAX_JOBS" ]; then
      wait
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
    image="$IMAGE"
    if [ -n "$CACHE_SEED" ]; then
      if group_is_seed_only "$gid"; then
        image="$(job_image)"
      else
        log "slot $slot: runner group '$GROUP' admits repositories other than ${CACHE_SEED%%:*}; this job starts without its build cache"
      fi
    fi
    name="$prefix-$slot-$(date +%s)"
    if ! response="$(request_jit "$name" "$gid" "$shared")"; then
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
    #
    # The container outlives its job only until keep_cache has looked at it.
    printf '%s\n' "$jit" | docker run --init -i --name "$name" \
      --memory "$MEMORY" --cpus "$CPUS" --pids-limit "$PIDS" --pull never \
      "$image" bash -c 'IFS= read -r jit && exec ./run.sh --jitconfig "$jit"' || rc=$?
    forget_runner "$id"
    if [ -n "$CACHE_SEED" ]; then
      keep_cache "$name" &
    else
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
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
  # What a supervisor that was killed left: its finished jobs' containers and
  # the lock keep_cache holds while it builds the cache image.
  docker ps -aq --filter "name=^$prefix-" | while read -r leftover; do
    docker rm -f "$leftover" >/dev/null 2>&1 || true
  done
  rmdir "$state_dir/keep-cache.lock" 2>/dev/null || true
  trap stop_slots INT TERM
  log "supervising $SLOTS slot(s), $QUEUE_SLOTS for the merge queue only, for label $LABEL in $ORG runner group $GROUP ($gid)"
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
    <key>LINUX_RUNNER_QUEUE_SLOTS</key><string>$QUEUE_SLOTS</string>
    <key>LINUX_RUNNER_MEMORY</key><string>$MEMORY</string>
    <key>LINUX_RUNNER_CPUS</key><string>$CPUS</string>
    <key>LINUX_RUNNER_PIDS</key><string>$PIDS</string>
    <key>LINUX_RUNNER_IMAGE</key><string>$IMAGE</string>
    <key>LINUX_RUNNER_CACHE_SEED</key><string>$CACHE_SEED</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$log_file</string>
  <key>StandardErrorPath</key><string>$log_file</string>
</dict>
</plist>
EOF
  replace_service "gui/$(id -u)" "$AGENT_ID" "$plist" "the fleet"
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
    <key>LINUX_RUNNER_QUEUE_SLOTS</key><string>$QUEUE_SLOTS</string>
    <key>LINUX_RUNNER_MEMORY</key><string>$MEMORY</string>
    <key>LINUX_RUNNER_CPUS</key><string>$CPUS</string>
    <key>LINUX_RUNNER_PIDS</key><string>$PIDS</string>
    <key>LINUX_RUNNER_IMAGE</key><string>$IMAGE</string>
    <key>LINUX_RUNNER_CACHE_SEED</key><string>$CACHE_SEED</string>
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
  replace_service system "$AGENT_ID" "$plist" "the fleet"
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
