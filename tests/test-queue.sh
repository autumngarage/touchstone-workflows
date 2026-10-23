#!/usr/bin/env bash
# Exercise the API selection itself (the supervisor integration tests stub its
# filtered output). Shapes follow GitHub's Actions runs/jobs and runner-group
# repository responses; IDs and labels below are local fixture values.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runner/queue.sh
. "$root/runner/queue.sh"
ORG=example
LABEL=mac-pool
FAIL_JOBS=0
mode=normal
# Run the production jq expressions against responses at the API boundary.
gh() {
  local endpoint="" expression="" response=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --paginate) shift ;;
      --jq) expression="$2"; shift 2 ;;
      *) endpoint="$1"; shift ;;
    esac
  done
  case "$endpoint" in
    */runner-groups/5/repositories)
      response='{"repositories":[{"full_name":"example/app","private":true}]}' ;;
    *runs?status=queued*) response='{"workflow_runs":[{"id":101}]}' ;;
    *runs?status=in_progress*) response='{"workflow_runs":[{"id":101},{"id":102}]}' ;;
    */runs/101/jobs*)
      [ "$FAIL_JOBS" = 0 ] || return 1
      response='{"jobs":[{"status":"queued","labels":["self-hosted","mac-pool"]},{"status":"completed","labels":["mac-pool"]},{"status":"queued","labels":["other-pool"]}]}' ;;
    */runs/102/jobs*)
      if [ "$mode" = malformed ]; then response='not json'
      else response='{"jobs":[{"status":"in_progress","labels":["mac-pool"]},{"status":"queued","labels":["self-hosted","mac-pool","mac-pool-shared"]}]}'
      fi ;;
    *) echo "unexpected API request: $endpoint" >&2; return 1 ;;
  esac
  printf '%s\n' "$response" | jq -r "$expression"
}
[ "$(waiting_jobs 5)" = '1 1' ] || { echo 'FAIL: partial runs, duplicate listings, completed jobs or foreign labels were miscounted' >&2; exit 1; }
echo '  OK: partially started runs count queued jobs once, filtered by fleet labels'
FAIL_JOBS=1
if waiting_jobs 5 >/dev/null; then echo 'FAIL: an unreadable job list became zero demand' >&2; exit 1; fi
FAIL_JOBS=0 mode=malformed
if waiting_jobs 5 >/dev/null 2>&1; then echo 'FAIL: malformed jobs became zero demand' >&2; exit 1; fi
echo '  OK: unavailable and malformed API responses preserve the fallback signal'
