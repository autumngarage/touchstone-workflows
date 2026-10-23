#!/usr/bin/env bash
# Existing overflow state-machine tests plus real API-shape regressions.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runner/linux-overflow.sh
. "$root/runner/linux-overflow.sh"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
CALLS="$STATE_DIR/calls"; QUEUED=""; MAIN=aaa
iso() { python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
epoch_of() { python3 -c 'import datetime,sys; print(int(datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$1"; }
FIXTURE="$root/tests/fixtures/overflow-current-checks.json"
RUNNER_FIXTURE="$root/tests/fixtures/overflow-runners.json"
RUNNERS="$RUNNER_FIXTURE"; FAIL_RUNNERS=0
CHECK_FIXTURE="$FIXTURE"; FAIL_API=0; FAIL_QUEUE=0
note() { :; }
add_event() { events+=("$*"); }
LINUX_HOME_REPOS=hesperus; ORG=autumngarage; USAGE_EVERY=21600; POLL=180
ago() { iso $(( $(date -u +%s) - $1 )); }
gh() {
  case "$*" in
    *actions/runners*) [ "$FAIL_RUNNERS" = 0 ] || return 1; cat "$RUNNERS" ;;
    *status=queued*) [ "$FAIL_QUEUE" = 0 ] || return 1; printf '%s' "$QUEUED" ;;
    *graphql*) [ "$FAIL_API" = 0 ] || return 1; cat "$CHECK_FIXTURE" ;;
    *commits/main*) printf '%s' "$MAIN" ;;
    *"workflow run"*) echo seed >>"$CALLS" ;;
    *) echo "unexpected gh $*" >>"$CALLS" ;;
  esac
}
set_linux_repos() { echo "repos=[$1]" >>"$CALLS"; }
failed=0
expect() { # label expected-calls expected-state(on|off)
  local got state=off
  got="$(tr '\n' ' ' <"$CALLS" 2>/dev/null | sed 's/ $//')"; [ -e "$STATE_DIR/linux-overflow" ] && state=on
  if [ "$got" = "$2" ] && [ "$state" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: calls [$got] state $state, expected [$2] $3"; failed=1; fi
  : >"$CALLS"
}
usage_sample() { printf '%s month=%s gross_usd=1 pct=%s projected_usd=1 allowance_usd=341\n' "$1" "$(date -u +%Y-%m)" "$2" >"$STATE_DIR/usage"; }
fresh() { MAIN=aaa; rm -f "$STATE_DIR"/linux-overflow "$STATE_DIR"/overflow-quiet "$STATE_DIR"/linux-failover "$STATE_DIR"/usage-fallback "$STATE_DIR"/usage; : >"$CALLS"; events=(); RUNNERS="$RUNNER_FIXTURE"; FAIL_RUNNERS=0; CHECK_FIXTURE="$FIXTURE"; FAIL_API=0; FAIL_QUEUE=0; date -u +%s >"$STATE_DIR/hosted-seed-last"; usage_sample "$(date -u +%s)" 15; }

fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"$'\n'"$(ago 60)"
check_linux_overflow; expect "off until enabled" "" off
touch "$STATE_DIR/overflow-enabled"

fresh; QUEUED="$(ago 1500)"
check_linux_overflow; expect "one validation waiting is not a backlog" "" off
fresh; QUEUED="$(ago 540)"$'\n'"$(ago 300)"$'\n'"$(ago 30)"
check_linux_overflow; expect "three waiting under ten minutes" "" off
fresh; QUEUED="$(ago 780)"$'\n'"$(ago 300)"
check_linux_overflow; expect "two waiting, the oldest thirteen minutes: to GitHub" "repos=[]" on
[ "${#events[@]}" -eq 1 ] && case "${events[0]}" in "2 hesperus validations are waiting"*"the oldest for 13 min"*) echo "ok   the event says how many and how long" ;; *) echo "FAIL event: ${events[0]}"; failed=1 ;; esac

fresh; echo 0 >"$STATE_DIR/hosted-seed-last"; QUEUED="$(ago 780)"$'\n'"$(ago 300)"
check_linux_overflow; expect "a stale hosted cache is seeded as the overflow begins" "repos=[] seed" on

# On: the two created before the move still wait for the Mac.
check_linux_overflow; expect "stays while runs made before the move are waiting" "" on
QUEUED="$(ago 5)"
check_linux_overflow; expect "stays for its minimum even with nothing left for the Mac" "" on
echo "$(( $(date -u +%s) - 1000 )) aaa" >"$STATE_DIR/linux-overflow"
check_linux_overflow; expect "back to the Mac once nothing made before the move is waiting" "repos=[hesperus]" off
echo "$(( $(date -u +%s) - 1000 )) aaa" >"$STATE_DIR/linux-overflow"; MAIN=bbb
check_linux_overflow; expect "and the Mac's cache is seeded when main moved meanwhile" "repos=[hesperus] seed" off

fresh; echo $(( $(date -u +%s) - 2000 )) >"$STATE_DIR/linux-overflow"; QUEUED="$(ago 3000)"
check_linux_overflow; expect "a run from before the move keeps it on past the minimum" "" on
jq --arg start "$(ago 1800)" --arg end "$(iso "$(date -u +%s)")" '
 .data.repository.pullRequests.nodes[0].commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0]
 |= (.conclusion="CANCELLED" | .startedAt=$start | .completedAt=$end | .databaseId=4242)
' "$FIXTURE" >"$STATE_DIR/timed-out.json"
CHECK_FIXTURE="$STATE_DIR/timed-out.json"
check_linux_overflow; expect "a hosted validation out of time ends it" "repos=[hesperus]" off
QUEUED="$(ago 1500)"$'\n'"$(ago 900)"; CHECK_FIXTURE="$FIXTURE"
check_linux_overflow; expect "and keeps it off while quiet" "" off
echo $(( $(date -u +%s) - 1 )) >"$STATE_DIR/overflow-quiet"
check_linux_overflow; expect "until the quiet time has passed" "repos=[]" on

fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"; usage_sample "$(date -u +%s)" 61
check_linux_overflow; expect "not past the usage cap" "" off
echo $(( $(date -u +%s) - 100 )) >"$STATE_DIR/linux-overflow"
check_linux_overflow; expect "and one that is on ends at the cap" "repos=[hesperus]" off

fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"; touch "$STATE_DIR/linux-failover"
check_linux_overflow; expect "an outage's failover owns the variable" "" off
fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"; echo "2026-10 1" >"$STATE_DIR/usage-fallback"
check_linux_overflow; expect "nor while the usage guard holds everything on the Mac" "" off

fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"
CI_WATCH_OVERFLOW_DRY_RUN=1 check_linux_overflow | grep -q "dry run: would send" && expect "a dry run moves nothing" "" off


for invalid in missing malformed stale future wrong-month negative-percent exhausted huge-percent unknown-cadence; do
  fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"
  case "$invalid" in
    missing) rm "$STATE_DIR/usage" ;;
    malformed) echo 'bad billing sample' >"$STATE_DIR/usage" ;;
    stale) usage_sample "$(( $(date -u +%s) - USAGE_EVERY - POLL - 5 ))" 15 ;;
    future) usage_sample "$(( $(date -u +%s) + 300 ))" 15 ;;
    wrong-month) sed 's/month=[0-9-]*/month=2000-01/' "$STATE_DIR/usage" >"$STATE_DIR/stale"; mv "$STATE_DIR/stale" "$STATE_DIR/usage" ;;
    negative-percent) usage_sample "$(date -u +%s)" -1 ;;
    exhausted) usage_sample "$(date -u +%s)" 60 ;;
    huge-percent) usage_sample "$(date -u +%s)" 9999999999999999999999999999 ;;
    unknown-cadence) USAGE_EVERY='' ;;
  esac
  check_linux_overflow; expect "unverified usage keeps local: $invalid" '' off
  echo "$(( $(date -u +%s) - 100 )) aaa" >"$STATE_DIR/linux-overflow"
  check_linux_overflow; expect "unverified usage restores local: $invalid" 'repos=[hesperus]' off
  USAGE_EVERY=21600
done
fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"
usage_sample "$(( $(date -u +%s) - USAGE_EVERY - POLL + 30 ))" 15
check_linux_overflow; expect 'usage remains valid through refresh cadence and one poll' 'repos=[]' on


# Projected from the live organization runner inventory on 2026-10-23.
# Three busy Linux slots plus an unrelated idle Mac must still permit overflow.
for patch in '.runners[4].busy=false' \
  '.runners |= map(select(any(.labels[]; .name == "linux-ephemeral") | not)) | .total_count=(.runners|length)' \
  '(.runners[] | select(any(.labels[]; .name == "linux-ephemeral"))).status="offline"' \
  '.total_count += 1' 'del(.runners[4].busy)' 'del(.runners[4].labels)' \
  '.runners[4].status="unknown"' 'del(.total_count)' 'empty'; do
  fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"
  jq "$patch" "$RUNNER_FIXTURE" >"$STATE_DIR/runners.json"; RUNNERS="$STATE_DIR/runners.json"
  check_linux_overflow
  expect "local without proven saturation: $patch" "" off
  echo "$(( $(date -u +%s) - 100 )) aaa" >"$STATE_DIR/linux-overflow"
  check_linux_overflow
  expect "active overflow returns local: $patch" "repos=[hesperus]" off
done
fresh; QUEUED="$(ago 1500)"$'\n'"$(ago 900)"; FAIL_RUNNERS=1
check_linux_overflow; expect 'runner API failure keeps local' '' off
echo "$(( $(date -u +%s) - 100 )) aaa" >"$STATE_DIR/linux-overflow"
check_linux_overflow; expect 'runner API failure restores local' 'repos=[hesperus]' off


# Reruns retain their old workflow creation time, but check timestamps describe
# the current attempt. This fixture is a projection of live GraphQL data from
# Hesperus PR #1476, a queue head and main on 2026-10-23; only case fields vary.
prcheck='.data.repository.pullRequests.nodes[0].commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0]'
began=1792778400 # 2026-10-23 18:00 UTC
parser_case() { # label jq-patch expected-output
  jq "$2" "$FIXTURE" >"$STATE_DIR/checks.json"
  CHECK_FIXTURE="$STATE_DIR/checks.json"
  local got
  got="$(recent_validation_timeout "$began")" || { echo "FAIL $1: parser error"; failed=1; return; }
  if [ "$got" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: [$got], expected [$3]"; failed=1; fi
}
cancel='(.conclusion="CANCELLED" | .startedAt="2026-10-23T18:01:00Z" | .completedAt="2026-10-23T18:31:00Z" | .databaseId=4242)'
parser_case 'current PR timeout is found without workflow created_at' "$prcheck |= $cancel" 4242
parser_case 'short manual cancellation is not a timeout' "$prcheck |= ($cancel | .completedAt=\"2026-10-23T18:02:00Z\")" ''
parser_case 'pre-overflow cancellation is ignored' "$prcheck |= ($cancel | .startedAt=\"2026-10-23T17:59:00Z\")" ''
parser_case 'explicit timed-out conclusion also stops overflow' "$prcheck |= ($cancel | .conclusion=\"TIMED_OUT\" | .completedAt=\"2026-10-23T18:02:00Z\")" 4242
parser_case 'Mac failures do not stop Linux overflow' "$prcheck |= ($cancel | .name=\"Build and test\")" ''
parser_case 'queue-head timeout is found' ".data.repository.mergeQueue.entries.nodes[0].headCommit.statusCheckRollup.contexts.nodes[0] |= $cancel" 4242
parser_case 'main-head timeout is found' ".data.repository.defaultBranchRef.target.statusCheckRollup.contexts.nodes[0] |= $cancel" 4242
parser_case 'queue entries without a candidate and fresh PRs without checks are allowed' '.data.repository.mergeQueue.entries.nodes[0].headCommit=null | .data.repository.pullRequests.nodes[0].commits.nodes[0].commit.statusCheckRollup=null' ''

for patch in '.data.repository.pullRequests.pageInfo.hasNextPage=true' \
  '.data.repository.mergeQueue.entries.pageInfo.hasNextPage=true' \
  '.data.repository.defaultBranchRef.target.statusCheckRollup.contexts.pageInfo.hasNextPage=true' \
  'del(.data.repository.pullRequests.pageInfo)' \
  'del(.data.repository.defaultBranchRef)' \
  '.data.repository.pullRequests.nodes[0].commits.nodes=[]' \
  '.errors=[{"message":"rate limited"}]'; do
  jq "$patch" "$FIXTURE" >"$STATE_DIR/invalid.json"
  CHECK_FIXTURE="$STATE_DIR/invalid.json"
  if recent_validation_timeout "$began" >/dev/null 2>&1; then echo "FAIL accepted $patch"; failed=1; else echo "ok   refuses $patch"; fi
done
for content in '' 'not JSON' '{}'; do
  printf '%s' "$content" >"$STATE_DIR/invalid.json"
  if recent_validation_timeout "$began" >/dev/null 2>&1; then echo "FAIL accepted invalid response [$content]"; failed=1; else echo "ok   refuses invalid response [$content]"; fi
done
fresh; echo $(( $(date -u +%s) - 1000 )) >"$STATE_DIR/linux-overflow"; FAIL_API=1
check_linux_overflow; expect 'unavailable attempt evidence returns to local' 'repos=[hesperus]' off
[ -s "$STATE_DIR/overflow-quiet" ] || { echo 'FAIL no quiet period after unavailable evidence'; failed=1; }
fresh; echo $(( $(date -u +%s) - 1000 )) >"$STATE_DIR/linux-overflow"; FAIL_QUEUE=1
check_linux_overflow; expect 'unavailable queue evidence returns to local' 'repos=[hesperus]' off

[ "$failed" = 0 ] || exit 1
