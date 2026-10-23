#!/usr/bin/env bash
# Queue/shared registration policy for the Linux and Mac supervisors.
# shellcheck disable=SC2034,SC2154
# Callers provide ORG, LABEL, SLOTS, QUEUE_SLOTS, state_dir, JANITOR_INTERVAL
# and the credential/group/JIT helpers from jit.sh. Bash 3.2 compatible.

# The role of a new runner: "queue" (queue-only) or "shared". A merge-queue
# job requires LABEL alone and every other job also LABEL-shared, so the labels
# of a job waiting for a runner say which kind it is.
#
# waiting_jobs GID: print "QUEUE PR", how many jobs of the group's repositories
# are waiting for a runner of this fleet, split by that kind. Multi-job Mac
# workflows can still have waiting jobs after another job starts.
waiting_jobs() {
  local repos repo runs run status jobs="" more
  repos="$(gh api --paginate "orgs/$ORG/actions/runner-groups/$1/repositories" \
    --jq '.repositories[] | "\(.full_name) \(.private)"')" || return 1
  while read -r repo _; do
    [ -n "$repo" ] || continue
    runs="$(for status in queued in_progress; do
      gh api --paginate "repos/$repo/actions/runs?status=$status&per_page=100" --jq '.workflow_runs[].id' || exit 1
    done)" || return 1
    # A run can start between the two listings; count its queued jobs once.
    runs="$(printf '%s\n' "$runs" | sort -u)"
    for run in $runs; do
      more="$(gh api --paginate "repos/$repo/actions/runs/$run/jobs?per_page=100" \
        --jq ".jobs[] | select(.status == \"queued\") | select(any(.labels[]; . == \"$LABEL\")) | if any(.labels[]; . == \"$LABEL-shared\") then \"pr\" else \"queue\" end")" || return 1
      jobs="$jobs$more
"
    done
  done <<EOF
$repos
EOF
  printf '%s %s\n' "$(printf '%s' "$jobs" | grep -c '^queue$' || true)" "$(printf '%s' "$jobs" | grep -c '^pr$' || true)"
}

# idle_queue_runners: how many of this host's queue-only runners are waiting
# for a job. GitHub's word, not the state file's: a runner that took a job
# still has its file, and it no longer waits for the next one.
idle_queue_runners() {
  local file id name role busy n=0
  for file in "$state_dir"/slot-*; do
    [ -f "$file" ] || continue
    read -r id name role <"$file" || continue
    [ "$role" = queue ] || continue
    busy="$(gh api "orgs/$ORG/actions/runners/$id" --jq .busy 2>/dev/null)" || continue
    if [ "$busy" = false ]; then n=$((n + 1)); fi
  done
  printf '%s\n' "$n"
}

# queue_only_runners: how many runners of this host are queue-only, idle or
# not. At most SLOTS-1 may be: a queue job can always use a shared runner, but
# a pull request can use nothing else, so one runner stays shared.
queue_only_runners() {
  local file id name role n=0
  for file in "$state_dir"/slot-*; do
    [ -f "$file" ] || continue
    read -r id name role <"$file" || continue
    if [ "$role" = queue ]; then n=$((n + 1)); fi
  done
  printf '%s\n' "$n"
}

# choose_role SLOT GID: print "queue" or "shared" for the runner SLOT is about
# to register. Where GitHub cannot say what waits, fall back to a fixed
# reservation: the first QUEUE_SLOTS slots are queue-only.
choose_role() {
  local slot="$1" counts queue pr idle
  if ! counts="$(waiting_jobs "$2")"; then
    log "slot $slot: could not read the jobs waiting for a runner; using the fixed reservation" >&2
    if [ "$slot" -le "$QUEUE_SLOTS" ]; then echo queue; else echo shared; fi
    return 0
  fi
  queue="${counts% *}"
  pr="${counts#* }"
  idle="$(idle_queue_runners)"
  if [ "$(queue_only_runners)" -ge $((SLOTS - 1)) ]; then
    echo shared
  elif [ "$queue" -gt "$idle" ]; then
    echo queue
  elif [ "$slot" -le "$QUEUE_SLOTS" ] && [ "$pr" -eq 0 ]; then
    echo queue
  else
    echo shared
  fi
}

# can_read_runs GID: warn, once per repository, when the token cannot read a
# group repository's workflow runs, which choose_role needs to see what waits.
can_read_runs() {
  local repo
  gh api --paginate "orgs/$ORG/actions/runner-groups/$1/repositories" \
    --jq '.repositories[].full_name' | while read -r repo; do
    gh api "repos/$repo/actions/runs?per_page=1" >/dev/null 2>&1 \
      || log "WARNING: the token cannot read the workflow runs of $repo (it needs Actions: read there), so runner roles use the fixed reservation of $QUEUE_SLOTS slot(s)"
  done
}

# janitor GID: every JANITOR_INTERVAL seconds, while pull-request jobs wait,
# remove the idle queue-only runners that no waiting queue job needs; the slot
# registers again with a fresh role. GitHub refuses to remove a runner that has
# a job (nothing is cut), and its success is the proof that this one had none.
janitor() {
  local gid="$1" counts queue pr file id name role busy keep
  while :; do
    sleep "$JANITOR_INTERVAL"
    counts="$(waiting_jobs "$gid")" || continue
    queue="${counts% *}"
    pr="${counts#* }"
    [ "$pr" -gt 0 ] || continue
    keep="$queue"
    for file in "$state_dir"/slot-*; do
      [ -f "$file" ] || continue
      read -r id name role <"$file" || continue
      [ "$role" = queue ] || continue
      busy="$(gh api "orgs/$ORG/actions/runners/$id" --jq .busy 2>/dev/null)" || continue
      [ "$busy" = false ] || continue
      if [ "$keep" -gt 0 ]; then
        keep=$((keep - 1))
        continue
      fi
      if gh api -X DELETE "orgs/$ORG/actions/runners/$id" >/dev/null 2>&1; then
        log "recycled idle queue-only runner $name: pull-request jobs wait and no queue job needs it"
      fi
    done
  done
}

# register_runner SLOT GID NAME: choose the role, register runner NAME with it,
# and write the slot's state file, all under one lock: two slots that free at
# once must not both answer the same waiting queue job. Sets role, jit and id in
# the caller; on failure sets err and returns 1, and returns 2 when the
# supervisor is draining, registering nothing.
register_runner() {
  local slot="$1" gid="$2" name="$3" lock="$state_dir/roles.lock" extra="" response
  role=shared jit="" id="" err=""
  until mkdir "$lock" 2>/dev/null; do sleep 1; done
  if [ -e "$state_dir/draining" ]; then
    rmdir "$lock"
    return 2
  fi
  if [ "$QUEUE_SLOTS" -gt 0 ]; then role="$(choose_role "$slot" "$gid")"; fi
  if [ "$role" = shared ]; then extra="$LABEL-shared"; fi
  if ! response="$(request_jit "$name" "$gid" "$extra")"; then
    err="could not register a runner ($response)"
    rmdir "$lock"
    return 1
  fi
  jit="$(printf '%s' "$response" | jq -r '.encoded_jit_config // empty')"
  id="$(printf '%s' "$response" | jq -r '.runner.id // empty')"
  if [ -z "$jit" ] || [ -z "$id" ]; then
    err="GitHub returned no runner configuration"
    rmdir "$lock"
    return 1
  fi
  printf '%s %s %s\n' "$id" "$name" "$role" >"$state_dir/slot-$slot"
  rmdir "$lock"
}

