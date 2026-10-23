#!/usr/bin/env bash
# Sourced by ci-watch: existing routing/usage state remains owned by the watcher.
# The caller provides STATE_DIR, ORG, LINUX_HOME_REPOS, set_linux_repos,
# note and add_event. Install alongside ci-watch.sh after source review.
OVERFLOW_WAIT=600
OVERFLOW_HOLD=900
OVERFLOW_USAGE_CAP=60
OVERFLOW_QUIET=10800
OVERFLOW_SEED_STALE=7200
# The protected validation has a 30-minute job limit; allow setup/teardown.
HOSTED_VALIDATE_LIMIT=1740

epoch_of() { date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null; }

main_sha() { gh api "repos/$ORG/hesperus/commits/main" --jq .sha 2>/dev/null; }

local_linux_saturated() {
  local response
  response="$(gh api "orgs/$ORG/actions/runners?per_page=100" 2>/dev/null)" || return 1
  printf '%s\n' "$response" | jq -sr '
    if length != 1 then error("missing runner inventory") else .[0] end
    | if (.runners | type) != "array" or (.total_count | type) != "number"
        or .total_count != (.runners | length)
      then error("incomplete runner inventory") else . end
    | if any(.runners[]; (.labels | type) != "array"
        or any(.labels[]; (.name | type) != "string")
        or (.busy | type) != "boolean"
        or (.status != "online" and .status != "offline"))
      then error("invalid runner inventory") else . end
    | [.runners[] | select(.status == "online"
        and any(.labels[]; .name == "linux-ephemeral"))]
    | length > 0 and all(.[]; .busy)'
}

recent_validation_timeout() { # overflow start epoch
  local response
  # Current heads bound the read without excluding reruns of older workflows.
  # Incomplete surfaces are an error, never evidence that hosting is healthy.
  # shellcheck disable=SC2016
  response="$(gh api graphql -f owner="$ORG" -f query='
    query($owner: String!) {
      repository(owner: $owner, name: "hesperus") {
        defaultBranchRef { target { ... on Commit { ...Checks } } }
        pullRequests(states: OPEN, first: 100) {
          pageInfo { hasNextPage }
          nodes { commits(last: 1) { nodes { commit { ...Checks } } } }
        }
        mergeQueue { entries(first: 100) {
          pageInfo { hasNextPage }
          nodes { headCommit { ...Checks } }
        } }
      }
    }
    fragment Checks on Commit {
      statusCheckRollup { contexts(first: 100) {
        pageInfo { hasNextPage }
        nodes { __typename ... on CheckRun {
          databaseId name conclusion startedAt completedAt
        } }
      } }
    }' 2>/dev/null)" || return 1
  printf '%s\n' "$response" | jq -sr --argjson began "$1" --argjson limit "$HOSTED_VALIDATE_LIMIT" '
    def surface: type == "object" and .pageInfo.hasNextPage == false and (.nodes | type) == "array";
    if length != 1 then error("missing overflow response") else .[0] end
    |
    if .errors or (.data.repository | type) != "object" then
      error("unreadable overflow check evidence")
    else .data.repository end
    | if (.pullRequests | surface | not)
      or (.mergeQueue.entries | surface | not)
      or (.defaultBranchRef.target | type) != "object"
      or any(.pullRequests.nodes[]; (.commits.nodes | length) != 1 or (.commits.nodes[0].commit | type) != "object")
      then error("incomplete overflow check evidence") else . end
    | [.defaultBranchRef.target,
       .pullRequests.nodes[].commits.nodes[].commit,
       .mergeQueue.entries.nodes[].headCommit | select(. != null)]
    | if any(.[]; .statusCheckRollup != null and (.statusCheckRollup.contexts | surface | not))
      then error("incomplete overflow check contexts") else . end
    | [.[].statusCheckRollup.contexts.nodes[]?
       | select(.__typename == "CheckRun" and .name == "validate (ubuntu-latest)")
       | select(.conclusion == "CANCELLED" or .conclusion == "TIMED_OUT")
       | (.startedAt | fromdateiso8601) as $start
       | (.completedAt | fromdateiso8601) as $end
       | select($start >= $began and ($end - $start >= $limit or .conclusion == "TIMED_OUT"))
       | .databaseId][0] // empty'
}

end_linux_overflow() { # why
  local state="$STATE_DIR/linux-overflow" began from now_at
  began="$(cut -d ' ' -f 1 "$state" 2>/dev/null)"; began="${began:-0}"
  from="$(cut -s -d ' ' -f 2 "$state" 2>/dev/null)"
  if [ -n "${CI_WATCH_OVERFLOW_DRY_RUN:-}" ]; then
    echo "dry run: would put hesperus's Linux jobs back on the Mac ($1)"
    return 0
  fi
  set_linux_repos "$LINUX_HOME_REPOS" || { note "overflow: could not put hesperus's Linux jobs back on the Mac"; return 1; }
  rm -f "$state"
  add_event "$1; hesperus's Linux jobs run on the Mac again (they went to GitHub for $(( ($(date -u +%s) - began) / 60 )) min)"
  now_at="$(main_sha)" || now_at=""
  if [ -n "$from" ] && [ -n "$now_at" ] && [ "$from" != "$now_at" ]; then
    gh workflow run swift-cache.yml --repo "$ORG/hesperus" --ref main >/dev/null 2>&1 \
      && note "overflow: main moved while it lasted; dispatched a seed for the Mac's cache"
  fi
}

check_linux_overflow() {
  local state="$STATE_DIR/linux-overflow" quiet="$STATE_DIR/overflow-quiet" now pct created at waiting=0 oldest=0 began late saturated
  [ -e "$STATE_DIR/overflow-enabled" ] || return 0
  [ -e "$STATE_DIR/linux-failover" ] && return 0
  [ -s "$STATE_DIR/usage-fallback" ] && return 0
  now="$(date -u +%s)"
  pct="$(tail -n 1 "$STATE_DIR/usage" 2>/dev/null | sed -n 's/.* pct=\([0-9][0-9]*\).*/\1/p')"
  if [ -e "$state" ]; then
    began="$(cut -d ' ' -f 1 "$state")"
    if [ "${pct:-0}" -ge "$OVERFLOW_USAGE_CAP" ]; then
      end_linux_overflow "hosted usage is at ${pct}% of what the plan covers, past the overflow's ${OVERFLOW_USAGE_CAP}%"
      return 0
    fi
    late="$(recent_validation_timeout "$began")" || {
      echo $(( now + OVERFLOW_QUIET )) >"$quiet"
      end_linux_overflow "could not verify current Linux validation attempts; overflow is off for $(( OVERFLOW_QUIET / 3600 )) h"
      return 0
    }
    if [ -n "$late" ]; then
      echo $(( now + OVERFLOW_QUIET )) >"$quiet"
      end_linux_overflow "a Linux validation exhausted its time allowance (check $late), so the overflow is off for $(( OVERFLOW_QUIET / 3600 )) h"
      return 0
    fi
  fi
  # Backlog alone does not prove the local fleet is full. Check current
  # capacity before admitting hosted work, and return as soon as a slot frees.
  # A missing/offline fleet belongs to the existing outage failover owner.
  saturated="$(local_linux_saturated)" || {
    note "overflow: could not verify local Linux runner capacity"
    [ ! -e "$state" ] || end_linux_overflow "could not verify local Linux runner capacity"
    return 0
  }
  if [ "$saturated" != true ]; then
    [ ! -e "$state" ] || end_linux_overflow "local Linux runner saturation is no longer established"
    return 0
  fi
  created="$(gh api "repos/$ORG/hesperus/actions/runs?status=queued&per_page=50" \
    --jq '.workflow_runs[] | select(.name == "validate") | .created_at' 2>/dev/null)" || {
    [ ! -e "$state" ] || end_linux_overflow "could not read waiting Linux validations"
    return 0
  }
  if [ -e "$state" ]; then
    # Still waiting for the Mac: created before the move.
    while IFS= read -r at; do
      [ -n "$at" ] || continue
      [ "$(epoch_of "$at" || echo "$now")" -lt "$began" ] && waiting=$(( waiting + 1 ))
    done <<<"$created"
    [ "$waiting" -eq 0 ] && [ $(( now - began )) -ge "$OVERFLOW_HOLD" ] && end_linux_overflow "the Mac's Linux slots have caught up"
    return 0
  fi

  [ "$now" -lt "$(cat "$quiet" 2>/dev/null || echo 0)" ] && return 0
  [ "${pct:-0}" -ge "$OVERFLOW_USAGE_CAP" ] && return 0
  while IFS= read -r at; do
    [ -n "$at" ] || continue
    at="$(epoch_of "$at")" || continue
    waiting=$(( waiting + 1 ))
    [ $(( now - at )) -gt "$oldest" ] && oldest=$(( now - at ))
  done <<<"$created"
  [ "$waiting" -ge 2 ] && [ "$oldest" -ge "$OVERFLOW_WAIT" ] || return 0
  if [ -n "${CI_WATCH_OVERFLOW_DRY_RUN:-}" ]; then
    echo "dry run: would send hesperus's new Linux jobs to GitHub ($waiting validations waiting, the oldest $(( oldest / 60 )) min)"
    return 0
  fi
  set_linux_repos "" || { note "overflow: could not move hesperus's Linux jobs to GitHub"; return 0; }
  echo "$now $(main_sha)" >"$state"
  add_event "$waiting hesperus validations are waiting for the Mac's Linux slots, the oldest for $(( oldest / 60 )) min; its new Linux jobs go to GitHub-hosted runners until those have run"
  # A hosted run restores the newest x64 cache; one that is hours old leaves
  # it most of a build to do inside its job limit.
  if [ $(( now - $(cat "$STATE_DIR/hosted-seed-last" 2>/dev/null || echo 0) )) -ge "$OVERFLOW_SEED_STALE" ]; then
    gh workflow run swift-cache.yml --repo "$ORG/hesperus" --ref main >/dev/null 2>&1 \
      && { echo "$now" >"$STATE_DIR/hosted-seed-last"; note "overflow: dispatched a hosted cache seed"; }
  fi
}

