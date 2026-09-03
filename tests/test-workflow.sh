#!/usr/bin/env bash
set -euo pipefail

repo_root="${TOUCHSTONE_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
workflow="$repo_root/.github/workflows/validate.yml"
review_gate="$repo_root/.github/workflows/review-gate.yml"
delivery_evidence="$repo_root/.github/workflows/delivery-evidence.yml"
source_contract="$repo_root/.touchstone-source-contract.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_count() {
  expected="$1"
  pattern="$2"
  actual="$(grep -Ec -- "$pattern" "$workflow" || true)"
  [ "$actual" -eq "$expected" ] || fail "expected $expected match(es) for $pattern, found $actual"
}

assert_active_line() {
  file="$1"
  expected="$2"
  label="$3"
  actual="$(sed '/^[[:space:]]*#/d; s/^[[:space:]]*//' "$file" | grep -Fxc -- "$expected" || true)"
  [ "$actual" -eq 1 ] || fail "$file: $label must be one active command"
}

assert_count 1 'name: validate \(ubuntu-latest\)'
assert_count 2 'uses: actions/checkout@[0-9a-f]{40}'
assert_count 1 'touchstone_revision="[0-9a-f]{40}"'
assert_count 1 'touchstone_sha256="[0-9a-f]{64}"'
assert_count 2 'raw\.githubusercontent\.com/autumngarage/touchstone/'
assert_count 2 'sha256sum --check --strict'
assert_count 1 'touchstone-run\.sh" validate'
# The workflow must pass the runner-provided variable literally.
# shellcheck disable=SC2016
assert_count 1 '--project "\$GITHUB_WORKSPACE"'
assert_count 1 '--json'
# The merge queue tests a temporary merge commit; a required check that does
# not report there ejects every queue entry.
assert_count 1 '^  merge_group:'
assert_count 1 'types: \[checks_requested\]'

if grep -Eq 'tests/test-\*\.sh|(^|[^[:alnum:]_-])(npm|pip|uv|brew|apt-get)([^[:alnum:]_-]|$)' "$workflow"; then
  fail "required workflow must invoke only the declaration engine"
fi

if grep -Eq 'TOUCHSTONE_(REVISION|SHA256)_PLACEHOLDER' "$workflow"; then
  fail "validator revision and checksum must be pinned before commit"
fi

# Required gates: pinned evaluator fetches with checksums, both PR and queue
# events, read-only tokens, no checkout of target code, no publication.
for gate in "$review_gate" "$delivery_evidence"; do
  grep -Eq 'touchstone_revision="[0-9a-f]{40}"' "$gate" || fail "$gate: evaluator revision is not pinned"
  grep -Eq 'evaluator_sha256="[0-9a-f]{64}"' "$gate" || fail "$gate: evaluator checksum is not pinned"
  grep -q 'sha256sum --check --strict' "$gate" || fail "$gate: checksum is not enforced"
  grep -q '^  merge_group:' "$gate" || fail "$gate: does not run on merge_group"
  grep -q '^  pull_request:' "$gate" || fail "$gate: does not run on pull_request"
  grep -q 'gh-readonly-queue' "$gate" || fail "$gate: cannot name the pull request behind a queue commit"
  if grep -Eq 'checks: write|statuses: write|contents: write' "$gate"; then fail "$gate: a required gate must not hold write permissions"; fi
  if grep -Eq 'uses: actions/checkout' "$gate" && ! grep -q "github.repository == 'autumngarage/touchstone-workflows'" "$gate"; then fail "$gate: checks out target code"; fi
done
for gate in "$review_gate" "$delivery_evidence"; do grep -q "PLACEHOLDER" "$gate" && fail "$gate: evaluator pins are placeholders"; done

# Behavior v1 binds each immutable fetch to the variable it pins and to an
# executed checksum command. Retaining those strings in comments or unused
# assignments is not evidence that the workflow enforces them.
# shellcheck disable=SC1003,SC2016
assert_active_line "$workflow" \
  '"https://raw.githubusercontent.com/autumngarage/touchstone/${touchstone_revision}/scripts/touchstone-run.sh" \' \
  "validator fetch"
assert_active_line "$workflow" \
  "printf '%s  %s\\n' \"\$touchstone_sha256\" \"\$validator\" | sha256sum --check --strict" \
  "validator checksum"
# The source manifest owns engine compatibility. The consumer workflow keeps
# the immutable values inline because required workflows execute in a target
# checkout, while this test makes drift between the two declarations fatal.
jq -e '
  .validationEngine.contractVersion == 1
  and (.validationEngine | keys == ["contractVersion", "path", "repository", "revision", "sha256", "supportedProjectSchemas"])
  and .validationEngine.repository == "autumngarage/touchstone"
  and .validationEngine.path == "scripts/touchstone-run.sh"
  and (.validationEngine.revision | test("^[0-9a-f]{40}$"))
  and (.validationEngine.sha256 | test("^[0-9a-f]{64}$"))
  and .validationEngine.supportedProjectSchemas == [1, 2]
' "$source_contract" >/dev/null || fail "$source_contract: invalid validation-engine contract"
manifest_engine_revision="$(jq -r '.validationEngine.revision' "$source_contract")"
manifest_engine_sha256="$(jq -r '.validationEngine.sha256' "$source_contract")"
workflow_engine_revision="$(sed -n 's/^[[:space:]]*touchstone_revision="\([0-9a-f][0-9a-f]*\)"$/\1/p' "$workflow")"
workflow_engine_sha256="$(sed -n 's/^[[:space:]]*touchstone_sha256="\([0-9a-f][0-9a-f]*\)"$/\1/p' "$workflow")"
[ "$workflow_engine_revision" = "$manifest_engine_revision" ] \
  || fail "$workflow: validator revision differs from $source_contract"
[ "$workflow_engine_sha256" = "$manifest_engine_sha256" ] \
  || fail "$workflow: validator checksum differs from $source_contract"
# shellcheck disable=SC1003,SC2016
assert_active_line "$workflow" \
  '"https://raw.githubusercontent.com/autumngarage/touchstone/${engine_revision}/${engine_path}" \' \
  "source-contract validator fetch"
assert_active_line "$workflow" \
  "printf '%s  %s\\n' \"\$engine_sha256\" \"\$validator\" | sha256sum --check --strict" \
  "source-contract validator checksum"
assert_active_line "$workflow" \
  "printf 'TOUCHSTONE_ENGINE_PATH=%s\\n' \"\$validator\" >>\"\$GITHUB_ENV\"" \
  "source-contract validator handoff"

if [ -n "${TOUCHSTONE_ENGINE_PATH:-}" ] && [ "${TOUCHSTONE_CONTRACT_SELF_TEST:-0}" != 1 ]; then
  [ -f "$TOUCHSTONE_ENGINE_PATH" ] || fail "declared validation engine is missing: $TOUCHSTONE_ENGINE_PATH"
  if command -v sha256sum >/dev/null 2>&1; then
    actual_engine_sha256="$(sha256sum "$TOUCHSTONE_ENGINE_PATH" | awk '{print $1}')"
  else
    actual_engine_sha256="$(shasum -a 256 "$TOUCHSTONE_ENGINE_PATH" | awk '{print $1}')"
  fi
  [ "$actual_engine_sha256" = "$manifest_engine_sha256" ] \
    || fail "declared validation engine checksum differs from $source_contract"

  engine_fixture="$(mktemp -d)"
  for schema in 1 2; do
    project="$engine_fixture/schema-$schema"
    mkdir -p "$project"
    printf '%s\n' \
      "schema = $schema" \
      '' \
      '[validation]' \
      'runtime = "bash"' \
      '' \
      '[[validation.targets]]' \
      'name = "root"' \
      'path = "."' \
      '' \
      '[[validation.tasks]]' \
      'name = "contract"' \
      'target = "root"' \
      'command = "true"' \
      'required = true' >"$project/.touchstone.toml"
    if [ "$schema" -eq 2 ]; then
      printf '%s\n' \
        '' \
        '[[validation.tasks]]' \
        'name = "authoring-guard"' \
        'target = "root"' \
        'stage = "commit"' \
        'command = "true"' \
        'required = true' >>"$project/.touchstone.toml"
    fi
    bash "$TOUCHSTONE_ENGINE_PATH" validate --project "$project" --check-contract --json >"$project/result.json" \
      || fail "declared validation engine rejected project schema $schema"
    jq -e --argjson schema "$schema" '.schema == $schema and .verdict == "valid"' "$project/result.json" >/dev/null \
      || fail "declared validation engine reported the wrong result for project schema $schema"
    bash "$TOUCHSTONE_ENGINE_PATH" validate --project "$project" --json >"$project/execution.json" \
      || fail "declared validation engine failed project schema $schema through the production path"
    jq -e '.verdict == "passed" and .ran == 1 and .skipped == 0 and .failed == 0' "$project/execution.json" >/dev/null \
      || fail "declared validation engine reported the wrong production result for project schema $schema"
  done
  rm -rf "$engine_fixture"
  echo "  OK: declared validation engine accepts project schemas 1 and 2"
fi
# shellcheck disable=SC1003,SC2016
assert_active_line "$review_gate" \
  '"https://raw.githubusercontent.com/autumngarage/touchstone/${touchstone_revision}/.github/review-gate/evaluate-v3.jq" \' \
  "review evaluator fetch"
# shellcheck disable=SC2016
assert_active_line "$review_gate" \
  'echo "${evaluator_sha256}  $RUNNER_TEMP/evaluate-v3.jq" | sha256sum --check --strict' \
  "review evaluator checksum"
assert_active_line "$review_gate" \
  'timeout-minutes: 65' \
  "review wait job timeout"
assert_active_line "$review_gate" \
  'REVIEW_REQUEST_WAIT_SECONDS: 120' \
  "review request wait bound"
assert_active_line "$review_gate" \
  'REVIEW_EVIDENCE_WAIT_SECONDS: 3600' \
  "review evidence wait bound"
assert_active_line "$review_gate" \
  'REST_REQUEST_LIMIT: 12' \
  "review REST request bound"
assert_active_line "$review_gate" \
  'MAX_EVIDENCE_PAGES: 4' \
  "review evidence page bound"
assert_active_line "$review_gate" \
  'REVIEW_POLL_SECONDS: 300' \
  "review poll interval"
assert_active_line "$review_gate" \
  'group: review-gate-${{ github.repository }}-${{ github.event.pull_request.number || github.ref }}' \
  "review run concurrency identity"
assert_active_line "$review_gate" \
  'cancel-in-progress: ${{ github.event_name == '\''pull_request'\'' }}' \
  "pull-request review run replacement"
assert_active_line "$review_gate" \
  'wait_for_review_gate' \
  "production waiting-state loop"
# Behavior v3 evaluates only current GitHub surfaces: the evidence document,
# the bounded resolver, and the pinned evaluator must each be one active
# command, and no prior-snapshot machinery may reappear.
assert_active_line "$review_gate" \
  'gateBehaviorContractVersion: 3, complete: true,' \
  "gate behavior contract version in evidence"
assert_active_line "$review_gate" \
  'resolve_head_prefix_candidates "$head" "$tmp/issues.json" "$tmp/issues-resolved.json"' \
  "bounded head-prefix resolution"
assert_active_line "$review_gate" \
  'jq -f "$RUNNER_TEMP/evaluate-v3.jq" "$tmp/evidence.json" >"$tmp/verdict.json"' \
  "pinned evaluator execution"
if grep -Eq 'priorIssueComments|priorReviewComments|evidenceCutoffAt|fixCommitReachability|authorPermissions' "$review_gate"; then
  fail "$review_gate: historical reconstruction machinery reappeared in behavior v3"
fi
# shellcheck disable=SC1003,SC2016
assert_active_line "$delivery_evidence" \
  '"https://raw.githubusercontent.com/autumngarage/touchstone/${touchstone_revision}/scripts/check-delivery-evidence.sh" \' \
  "delivery evaluator fetch"
# shellcheck disable=SC2016
assert_active_line "$delivery_evidence" \
  'echo "${evaluator_sha256}  $RUNNER_TEMP/check-delivery-evidence.sh" | sha256sum --check --strict' \
  "delivery evaluator checksum"
# shellcheck disable=SC2016
assert_active_line "$review_gate" \
  'fetch_pull_request "$event_mode" "$number" "$event_head" "$event_base_ref" "$tmp/pr.json"' \
  "production coordinate validation"

echo "==> behavior-v2 workflows share refresh triggers and use read-only permissions"
for gate in "$workflow" "$review_gate" "$delivery_evidence"; do
  ruby -rpsych -e '
    pairs = lambda do |node, label|
      raise "#{label} must be a mapping" unless node.is_a?(Psych::Nodes::Mapping)
      node.children.each_slice(2).to_a
    end
    scalar = lambda do |node, label|
      raise "#{label} must be a scalar" unless node.is_a?(Psych::Nodes::Scalar)
      node.value
    end
    one = lambda do |entries, name, label|
      matches = entries.select { |key, _| scalar.call(key, label) == name }
      raise "#{label} must declare #{name} exactly once" unless matches.length == 1
      matches.first.fetch(1)
    end

    root = pairs.call(Psych.parse_file(ARGV.fetch(0)).root, "workflow")
    triggers = pairs.call(one.call(root, "on", "workflow"), "on")
    pull_request = one.call(triggers, "pull_request", "on")
    fields = pairs.call(pull_request, "pull_request")
    raise "pull_request must declare only types" unless fields.length == 1
    types = one.call(fields, "types", "pull_request")
    raise "pull_request types must be a sequence" unless types.is_a?(Psych::Nodes::Sequence)
    actual = types.children.map { |node| scalar.call(node, "pull_request type") }.sort
    required = %w[edited opened ready_for_review reopened synchronize]
    raise "pull_request types must cover #{required.join(", ")}" unless actual == required

    merge_group = pairs.call(one.call(triggers, "merge_group", "on"), "merge_group")
    raise "merge_group must declare only types" unless merge_group.length == 1
    merge_types = one.call(merge_group, "types", "merge_group")
    raise "merge_group types must be a sequence" unless merge_types.is_a?(Psych::Nodes::Sequence)
    actual_merge_types = merge_types.children.map { |node| scalar.call(node, "merge_group type") }
    raise "merge_group types must be checks_requested" unless actual_merge_types == ["checks_requested"]

    permissions = pairs.call(one.call(root, "permissions", "workflow"), "permissions")
    raise "permissions must not be empty" if permissions.empty?
    declared_permissions = []
    permissions.each do |key, value|
      name = scalar.call(key, "permission name")
      level = scalar.call(value, "permission #{name}")
      raise "permission #{name} must be read-only" unless level == "read"
      declared_permissions << name
    end
    required_permissions = case File.basename(ARGV.fetch(0))
      when "review-gate.yml" then %w[contents issues pull-requests]
      when "delivery-evidence.yml" then %w[contents pull-requests]
      when "validate.yml" then %w[contents]
      else raise "unexpected behavior-v2 workflow"
    end
    missing_permissions = required_permissions - declared_permissions
    raise "missing read permissions: #{missing_permissions.join(", ")}" unless missing_permissions.empty?

    jobs = pairs.call(one.call(root, "jobs", "workflow"), "jobs")
    jobs.each do |job_key, configuration|
      job = scalar.call(job_key, "job ID")
      fields = pairs.call(configuration, "job #{job}")
      if fields.any? { |key, _| scalar.call(key, "job #{job} key") == "permissions" }
        raise "job #{job} must not override permissions"
      end
    end
  ' "$gate" || fail "$gate: violates behavior-v2 trigger or permission invariants"
done
echo "  OK: triggers and effective permissions are structurally bound"

echo "==> review polling preserves repository API headroom at concurrent scale"
production_poll_seconds="$(sed -n 's/^[[:space:]]*REVIEW_POLL_SECONDS: \([0-9][0-9]*\)$/\1/p' "$review_gate")"
production_request_limit="$(sed -n 's/^[[:space:]]*REST_REQUEST_LIMIT: \([0-9][0-9]*\)$/\1/p' "$review_gate")"
standard_hourly_budget=1000
reserved_budget=$((standard_hourly_budget / 5))
concurrent_waiting_prs=3
projected_requests=$((concurrent_waiting_prs * (3600 / production_poll_seconds) * production_request_limit))
[ $((projected_requests + reserved_budget)) -le "$standard_hourly_budget" ] \
  || fail "review polling consumes $projected_requests requests/hour and leaves less than $reserved_budget requests of headroom"
direct_rest_calls="$(grep -nE '^[[:space:]]*gh api ' "$review_gate" | grep -v 'gh api "\$@"' | grep -v 'gh api graphql' || true)"
[ -z "$direct_rest_calls" ] \
  || fail "review evidence bypasses the enforced REST request boundary: $direct_rest_calls"

budget_fixture="$(mktemp -d)"
awk '
  /touchstone:rest-budget:start/ { copying = 1; next }
  /touchstone:rest-budget:end/ { copying = 0 }
  copying { sub(/^          /, ""); print }
' "$review_gate" >"$budget_fixture/budget.sh"
# shellcheck source=/dev/null
source "$budget_fixture/budget.sh"
tmp="$budget_fixture/evidence"
mkdir -p "$tmp"
printf '0\n' >"$tmp/rest-request-count"
REST_REQUEST_LIMIT=2
budget_calls="$budget_fixture/calls"
: >"$budget_calls"
gh() { printf '%s\n' "$*" >>"$budget_calls"; printf '{}\n'; }
rest_api first >/dev/null || fail "REST budget rejected its first request"
rest_api second >/dev/null || fail "REST budget rejected its boundary request"
if rest_api third >/dev/null 2>&1; then
  fail "REST budget allowed a request beyond its enforced limit"
fi
[ "$(wc -l <"$budget_calls" | tr -d ' ')" -eq 2 ] \
  || fail "REST budget invoked gh after reaching its enforced limit"
REST_REQUEST_LIMIT=20
MAX_EVIDENCE_PAGES=2
printf '0\n' >"$tmp/rest-request-count"
gh() { jq -cn '[range(0;100) | {}]'; }
if api_array 'repos/example/project/issues/1/comments?per_page=100' "$budget_fixture/pages.json" >/dev/null 2>"$budget_fixture/pages.err"; then
  fail "evidence pagination beyond MAX_EVIDENCE_PAGES did not fail closed"
fi
grep -Fq "supported bound of 2 evidence pages" "$budget_fixture/pages.err" \
  || fail "page-bound failure lost its diagnostic: $(cat "$budget_fixture/pages.err")"
unset -f gh
rm -rf "$budget_fixture"
echo "  OK: enforced $production_request_limit-request evaluations consume at most $projected_requests requests/hour and leave $((standard_hourly_budget - projected_requests)) for unrelated work"

echo "==> review-gate resolves only trusted head-prefix result candidates"
resolve_fixture="$(mktemp -d)"
trap 'rm -rf "$resolve_fixture"' EXIT HUP INT TERM
awk '
  /touchstone:rest-budget:start/ { copying = 1; next }
  /touchstone:rest-budget:end/ { copying = 0 }
  copying { sub(/^          /, ""); print }
' "$review_gate" >"$resolve_fixture/budget.sh"
awk '
  /touchstone:abbrev-resolution:start/ { copying = 1; next }
  /touchstone:abbrev-resolution:end/ { copying = 0 }
  copying { sub(/^          /, ""); print }
' "$review_gate" >"$resolve_fixture/resolver.sh"
# shellcheck source=/dev/null
source "$resolve_fixture/budget.sh"
# shellcheck source=/dev/null
source "$resolve_fixture/resolver.sh"
tmp="$resolve_fixture/evidence"
mkdir -p "$tmp"
# Used by the sourced production resolver.
# shellcheck disable=SC2034
REPO=example/project
# shellcheck disable=SC2034
TRUSTED_REVIEWERS=trusted-bot
REST_REQUEST_LIMIT=20
MAX_EVIDENCE_PAGES=4
printf '0\n' >"$tmp/rest-request-count"
resolve_head=1111111abc111111111111111111111111111111
resolve_calls="$resolve_fixture/calls"
: >"$resolve_calls"
gh() {
  [ "$1" = api ] || return 99
  printf '%s\n' "$2" >>"$resolve_calls"
  case "$2" in
    *commits/1111111abc) printf '%s\n' "$resolve_head" ;;
    *commits/1111111) echo 'gh: ambiguous (HTTP 422)' >&2; return 1 ;;
    *) return 98 ;;
  esac
}
cat >"$resolve_fixture/issues.json" <<EOF_RESOLVE
[{"id":1,"user":{"login":"trusted-bot"},"body":"Didn't find any major issues.\n\n**Reviewed commit:** \`1111111abc\`"},
 {"id":2,"user":{"login":"trusted-bot"},"body":"Didn't find any major issues.\n\n**Reviewed commit:** \`1111111abc\`"},
 {"id":3,"user":{"login":"trusted-bot"},"body":"Didn't find any major issues.\n\n**Reviewed commit:** \`1111111\`"},
 {"id":4,"user":{"login":"trusted-bot"},"body":"Old result.\n\n**Reviewed commit:** \`9999999\`"},
 {"id":5,"user":{"login":"impostor"},"body":"Didn't find any major issues.\n\n**Reviewed commit:** \`1111111abc\`"}]
EOF_RESOLVE
resolve_head_prefix_candidates "$resolve_head" "$resolve_fixture/issues.json" \
  "$resolve_fixture/resolved.json" || fail "head-prefix resolution failed"
jq -e --arg head "$resolve_head" '
  .[0].resolved_review_sha == $head
  and .[1].resolved_review_sha == $head
  and .[2].resolved_review_sha == ""
  and (.[3] | has("resolved_review_sha") | not)
  and (.[4] | has("resolved_review_sha") | not)
' "$resolve_fixture/resolved.json" >/dev/null \
  || fail "resolution results are wrong: $(jq -c 'map(.resolved_review_sha)' "$resolve_fixture/resolved.json")"
# One request per unique candidate abbreviation: a repeated abbreviation, a
# stale prefix, and an untrusted author spend nothing beyond the two
# candidates; the ambiguous one records failure instead of a verdict.
[ "$(wc -l <"$resolve_calls" | tr -d ' ')" -eq 2 ] \
  || fail "resolution spent $(wc -l <"$resolve_calls" | tr -d ' ') REST requests, expected 2: $(cat "$resolve_calls")"
grep -q "commits/9999999" "$resolve_calls" \
  && fail "a stale non-prefix abbreviation spent a REST request"
unset -f gh
rm -rf "$resolve_fixture"
trap - EXIT HUP INT TERM
echo "  OK: dedupe, stale prefixes, untrusted authors, and unresolvable candidates are explicit"

echo "==> review-gate waits only for pull-request evidence states"
wait_fixture="$(mktemp -d)"
trap 'rm -rf "$wait_fixture"' EXIT HUP INT TERM
awk '
  /touchstone:review-wait:start/ { copying = 1; next }
  /touchstone:review-wait:end/ { copying = 0 }
  copying { sub(/^          /, ""); print }
' "$review_gate" >"$wait_fixture/wait.sh"
# shellcheck source=/dev/null
source "$wait_fixture/wait.sh"

run_wait_case() {
  label="$1"
  sequence="$2"
  event="$3"
  expected_result="$4"
  expected_calls="$5"
  request_wait="${6:-120}"
  evidence_wait="${7:-120}"
  tmp="$wait_fixture/$label"
  mkdir -p "$tmp"
  IFS=, read -r -a WAIT_STATES <<<"$sequence"
  WAIT_CALLS=0
  MOCK_NOW=0
  event_mode="$event"
  REVIEW_REQUEST_WAIT_SECONDS="$request_wait"
  REVIEW_EVIDENCE_WAIT_SECONDS="$evidence_wait"
  REVIEW_POLL_SECONDS="${8:-60}"
  EVALUATION_SECONDS="${9:-0}"

  evaluate_once() {
    index="$WAIT_CALLS"
    if [ "$index" -ge "${#WAIT_STATES[@]}" ]; then index=$((${#WAIT_STATES[@]} - 1)); fi
    state="${WAIT_STATES[$index]}"
    WAIT_CALLS=$((WAIT_CALLS + 1))
    jq -n --arg state "$state" '{state: $state, summary: ("summary: " + $state)}' >"$tmp/verdict.json"
    MOCK_NOW=$((MOCK_NOW + EVALUATION_SECONDS))
  }
  review_gate_now() { printf '%s\n' "$MOCK_NOW"; }
  review_gate_sleep() { MOCK_NOW=$((MOCK_NOW + $1)); }

  if [ "$expected_result" = success ]; then
    wait_for_review_gate >"$tmp/output" 2>&1 || fail "$label: expected success"
  elif wait_for_review_gate >"$tmp/output" 2>&1; then
    fail "$label: expected failure"
  fi
  [ "$WAIT_CALLS" -eq "$expected_calls" ] \
    || fail "$label: expected $expected_calls evaluation(s), got $WAIT_CALLS"
  echo "  OK: $label"
}

run_wait_case "request-review-success" "waiting-request,waiting-review,success" pull_request success 3
run_wait_case "terminal-failure" "failure" pull_request failure 1
run_wait_case "merge-group-never-waits" "waiting-review" merge_group failure 1
run_wait_case "request-deadline" "waiting-request" pull_request failure 3
run_wait_case "review-deadline" "waiting-review" pull_request failure 3
run_wait_case "request-deadline-caps-long-poll" "waiting-request,success" pull_request success 2 120 120 180
run_wait_case "request-starts-full-review-window" "waiting-request,waiting-review,waiting-review,success" pull_request success 4 60 180 60
run_wait_case "unknown-state" "unknown" pull_request failure 1
rm -rf "$wait_fixture"

echo "==> review-gate binds evidence to event PR coordinates"
coordinate_fixture="$(mktemp -d)"
trap 'rm -rf "$coordinate_fixture"' EXIT HUP INT TERM
awk '
  /touchstone:pr-coordinate:start/ { copying = 1; next }
  /touchstone:pr-coordinate:end/ { copying = 0 }
  copying { sub(/^          /, ""); print }
' "$review_gate" >"$coordinate_fixture/coordinate.sh"
# shellcheck source=/dev/null
source "$coordinate_fixture/coordinate.sh"
REPO=example/project
GITHUB_EVENT_PATH="$coordinate_fixture/event.json"
requested_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
requested_base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq -n --arg head "$requested_head" --arg base "$requested_base" \
  '{pull_request:{number:17,head:{sha:$head},base:{sha:$base,ref:"main"}}}' >"$GITHUB_EVENT_PATH"
# Referenced by the sourced production function.
# shellcheck disable=SC2034
GITHUB_EVENT_NAME=pull_request
event_pull_request_coordinates >"$coordinate_fixture/coordinates.json"
jq -e --arg head "$requested_head" --arg base "$requested_base" \
  '. == {mode:"pull_request",number:17,headSha:$head,baseSha:$base,baseRef:"main"}' "$coordinate_fixture/coordinates.json" >/dev/null \
  || fail "pull_request event selected the wrong coordinates"
queue_head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
jq -n --arg head "$queue_head" --arg base "$requested_base" \
  '{merge_group:{head_ref:("refs/heads/gh-readonly-queue/main/pr-23-" + $base),head_sha:$head,base_sha:$base}}' >"$GITHUB_EVENT_PATH"
# Referenced by the sourced production function.
# shellcheck disable=SC2034
GITHUB_EVENT_NAME=merge_group
event_pull_request_coordinates >"$coordinate_fixture/coordinates.json"
jq -e --arg head "$queue_head" --arg base "$requested_base" \
  '. == {mode:"merge_group",number:23,headSha:$head,baseSha:$base,baseRef:""}' "$coordinate_fixture/coordinates.json" >/dev/null \
  || fail "merge_group event selected the wrong coordinates"
jq -n --arg head "$queue_head" --arg base "$requested_base" \
  '{merge_group:{head_ref:("refs/heads/gh-readonly-queue/main/pr-23-" + $head),head_sha:$head,base_sha:$base}}' >"$GITHUB_EVENT_PATH"
if event_pull_request_coordinates >/dev/null 2>&1; then
  fail "merge_group event accepted a queue ref not bound to its base"
fi

# Called by the sourced production function.
# shellcheck disable=SC2329
gh() {
  [ "$1" = api ] || return 99
  jq -n --argjson number "${GH_FIXTURE_NUMBER:-17}" \
    --arg head "${GH_FIXTURE_HEAD:-$requested_head}" --arg base "${GH_FIXTURE_BASE:-$requested_base}" \
    --arg baseRef "${GH_FIXTURE_BASE_REF:-main}" \
    '{number:$number,head:{sha:$head},base:{sha:$base,ref:$baseRef}}'
}
rest_api() { gh api "$@"; }
fetch_pull_request pull_request 17 "$requested_head" main "$coordinate_fixture/pr.json" \
  || fail "matching PR coordinates were rejected"
for mismatch in number head base-ref; do
  unset GH_FIXTURE_NUMBER GH_FIXTURE_HEAD GH_FIXTURE_BASE GH_FIXTURE_BASE_REF
  case "$mismatch" in
    number) GH_FIXTURE_NUMBER=18 ;;
    head) GH_FIXTURE_HEAD=cccccccccccccccccccccccccccccccccccccccc ;;
    base-ref) GH_FIXTURE_BASE_REF=release ;;
  esac
  if fetch_pull_request pull_request 17 "$requested_head" main "$coordinate_fixture/pr.json" >/dev/null 2>&1; then
    fail "review gate accepted mismatched $mismatch coordinates"
  fi
done
unset GH_FIXTURE_NUMBER GH_FIXTURE_HEAD GH_FIXTURE_BASE GH_FIXTURE_BASE_REF
GH_FIXTURE_BASE=dddddddddddddddddddddddddddddddddddddddd
fetch_pull_request pull_request 17 "$requested_head" main "$coordinate_fixture/pr.json" \
  || fail "pull-request event rejected an advanced base SHA on the same ref"
unset GH_FIXTURE_BASE
GH_FIXTURE_HEAD=cccccccccccccccccccccccccccccccccccccccc
GH_FIXTURE_BASE=dddddddddddddddddddddddddddddddddddddddd
fetch_pull_request merge_group 17 "$queue_head" "" "$coordinate_fixture/pr.json" \
  || fail "merge-group event mistook queue coordinates for PR head/base"
unset GH_FIXTURE_HEAD GH_FIXTURE_BASE
rm -rf "$coordinate_fixture"
trap - EXIT HUP INT TERM
echo "  OK: PR head/ref and queue coordinates fail closed without freezing an advancing base SHA"

# The repository policy requires one literal status context. Keep that name in
# a machine-readable manifest so the policy engine can compare its desired rule
# with its one publisher instead of relying on an ambiguous duplicate context.
command -v jq >/dev/null 2>&1 || fail "jq is required to validate the source contract"
command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse workflow YAML"
jq -e '
  . as $contract
  | .contractVersion == 1
  and .gateBehaviorContractVersion == 3
  and (.requiredStatusCheck
    | type == "string"
    and test("^[A-Za-z0-9][A-Za-z0-9 ._()/-]*\\z"))
  and (.sourceRepository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\z"))
  and (.statusJob | type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*\\z"))
  and (.statusPublisher | type == "string")
  and (.workflowPaths | type == "array" and length > 0 and length == (unique | length))
  and ($contract.workflowPaths | index($contract.statusPublisher) != null)
  and all(.workflowPaths[];
    type == "string"
    and startswith(".github/workflows/")
    and (endswith(".yml") or endswith(".yaml")))
' "$source_contract" >/dev/null || fail "source contract manifest is malformed"
required_status_check="$(jq -er '.requiredStatusCheck' "$source_contract")"
source_repository="$(jq -er '.sourceRepository' "$source_contract")"
status_job="$(jq -er '.statusJob' "$source_contract")"
status_publisher="$(jq -er '.statusPublisher' "$source_contract")"
manifest_workflow_count="$(jq -r '.workflowPaths | length' "$source_contract")"
repository_workflow_count=0
for gate in \
  "$repo_root"/.github/workflows/*.yml "$repo_root"/.github/workflows/*.yaml \
  "$repo_root"/.github/workflows/.*.yml "$repo_root"/.github/workflows/.*.yaml; do
  [ -f "$gate" ] || continue
  repository_workflow_count=$((repository_workflow_count + 1))
  relative_gate="${gate#"$repo_root"/}"
  jq -e --arg path "$relative_gate" '.workflowPaths | index($path) != null' "$source_contract" >/dev/null \
    || fail "$relative_gate: workflow is absent from the source contract manifest"
  if ! published_jobs="$(ruby -rpsych -e '
    pairs = lambda do |node, label|
      raise "#{label} must be a mapping" unless node.is_a?(Psych::Nodes::Mapping)
      node.children.each_slice(2).to_a
    end
    scalar = lambda do |node, label|
      raise "#{label} must be a scalar" unless node.is_a?(Psych::Nodes::Scalar)
      node.value
    end

    root = Psych.parse_file(ARGV.fetch(0)).root
    root_pairs = pairs.call(root, "workflow")
    root_pairs.each { |key, _| scalar.call(key, "workflow key") }
    jobs_entries = root_pairs.select { |key, _| key.value == "jobs" }
    raise "workflow must declare exactly one jobs mapping" unless jobs_entries.length == 1
    jobs = pairs.call(jobs_entries.first.fetch(1), "jobs")
    seen_jobs = {}
    jobs.each do |job_node, configuration|
      job = scalar.call(job_node, "job ID")
      raise "invalid job ID: #{job.inspect}" unless job.match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/)
      raise "duplicate job ID: #{job}" if seen_jobs[job]
      seen_jobs[job] = true

      fields = pairs.call(configuration, "job #{job}")
      fields.each { |key, _| scalar.call(key, "job #{job} key") }
      names = fields.select { |key, _| key.value == "name" }
      raise "job #{job} declares name more than once" if names.length > 1
      name = names.empty? ? nil : scalar.call(names.first.fetch(1), "job #{job} name")
      if name && !name.match?(/\A[A-Za-z0-9][A-Za-z0-9 ._()\/-]*\z/)
        raise "job #{job} name must be a literal in the source contract character set"
      end
      effective_name = name || job
      if job == ARGV.fetch(3) && effective_name == ARGV.fetch(1) && ARGV.fetch(4) == ARGV.fetch(5)
        guards = fields.select { |key, _| key.value == "if" }
        raise "status publisher must declare one repository guard" unless guards.length == 1
        guard = scalar.call(guards.first.fetch(1), "status publisher guard")
        expected_guard = "github.repository == " + 39.chr + ARGV.fetch(2) + 39.chr
        raise "status publisher has the wrong repository guard" unless guard == expected_guard
      end
      puts job if effective_name == ARGV.fetch(1)
    end
  ' "$gate" "$required_status_check" "$source_repository" "$status_job" "$relative_gate" "$status_publisher")"; then
    fail "$relative_gate: workflow jobs or names are malformed"
  fi
  if [ -n "$published_jobs" ]; then
    [ "$relative_gate" = "$status_publisher" ] \
      || fail "$relative_gate: duplicates required status '$required_status_check' owned by $status_publisher"
    [ "$published_jobs" = "$status_job" ] \
      || fail "$relative_gate: required status '$required_status_check' must be published only by job $status_job"
  else
    [ "$relative_gate" != "$status_publisher" ] \
      || fail "$relative_gate: source-contract job does not publish '$required_status_check'"
  fi
done
[ "$repository_workflow_count" -eq "$manifest_workflow_count" ] \
  || fail "source contract manifest names $manifest_workflow_count workflows, repository has $repository_workflow_count"

if [ "${TOUCHSTONE_CONTRACT_SELF_TEST:-0}" != 1 ]; then
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT HUP INT TERM
  mkdir -p "$fixture/.github"
  cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
  cp "$source_contract" "$fixture/.touchstone-source-contract.json"
  if ! TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 \
    TOUCHSTONE_ENGINE_PATH=/missing/recursive-engine bash "$0" >"$fixture/self-test.out" 2>&1; then
    cat "$fixture/self-test.out" >&2
    fail "recursive source-contract checks reran top-level validation-engine fixtures"
  fi
  rm -r "$fixture"

  expression_status="\${{ '$required_status_check' }}"
  for job_indent in '    ' '      '; do
    for status_key in name "'name'" '"name"' '"na\u006de"'; do
      for status_spelling in "$required_status_check" "$required_status_check   " "'$required_status_check'" "\"$required_status_check\"" "$expression_status"; do
        fixture="$(mktemp -d)"
        trap 'rm -rf "$fixture"' EXIT HUP INT TERM
        mkdir -p "$fixture/.github"
        cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
        cp "$source_contract" "$fixture/.touchstone-source-contract.json"
        printf '%s\n' \
          '# Comments do not end the jobs mapping, regardless of indentation.' \
          '  duplicate-source-contract: # Inline comments preserve a block mapping.' \
          "$job_indent$status_key: $status_spelling" \
          "${job_indent}runs-on: ubuntu-latest" \
          "${job_indent}steps: []" >>"$fixture/$status_publisher"
        if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
          fail "source contract accepted a duplicate status publisher under another job ID"
        fi
        if [ "$status_spelling" = "$expression_status" ]; then
          grep -Fq "workflow jobs or names are malformed" "$fixture/self-test.out" \
            || fail "expression-based job name did not fail the literal-name invariant"
        else
          grep -Fq "must be published only by job $status_job" "$fixture/self-test.out" \
            || fail "YAML-equivalent duplicate status publisher did not fail for ownership"
        fi
        rm -r "$fixture"
      done
    done
  done
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT HUP INT TERM
  mkdir -p "$fixture/.github"
  cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
  cp "$source_contract" "$fixture/.touchstone-source-contract.json"
  printf '  duplicate-source-contract: {name: %s, runs-on: ubuntu-latest, steps: []}\n' \
    "$required_status_check" >>"$fixture/$status_publisher"
  if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
    fail "source contract accepted a duplicate status publisher in a flow-style job mapping"
  fi
  grep -Fq "must be published only by job $status_job" "$fixture/self-test.out" \
    || fail "flow-style duplicate did not fail for the ownership invariant"
  rm -r "$fixture"

  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT HUP INT TERM
  mkdir -p "$fixture/.github"
  cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
  hidden_workflow=".github/workflows/.duplicate.yml"
  cp "$fixture/$status_publisher" "$fixture/$hidden_workflow"
  jq --arg path "$hidden_workflow" '.workflowPaths += [$path]' \
    "$source_contract" >"$fixture/.touchstone-source-contract.json"
  if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
    fail "source contract accepted a dot-prefixed duplicate status publisher"
  fi
  grep -Fq "duplicates required status '$required_status_check'" "$fixture/self-test.out" \
    || fail "dot-prefixed workflow did not fail for duplicate status ownership"
  rm -r "$fixture"

  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT HUP INT TERM
  mkdir -p "$fixture/.github"
  cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
  cp "$source_contract" "$fixture/.touchstone-source-contract.json"
  printf '%s\n' \
    '  on:' \
    '    name: scheduled source audit' \
    '    runs-on: ubuntu-latest' \
    '    env:' \
    '      RELEASE_DATE: 2026-08-23' \
    '    steps: []' >>"$fixture/$status_publisher"
  if ! TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
    cat "$fixture/self-test.out" >&2
    fail "source contract rejected valid GitHub YAML scalar spellings"
  fi
  rm -r "$fixture"

  for manifest_identifier in requiredStatusCheck sourceRepository statusJob; do
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT HUP INT TERM
    mkdir -p "$fixture/.github"
    cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
    jq --arg field "$manifest_identifier" '.[$field] += "\n"' \
      "$source_contract" >"$fixture/.touchstone-source-contract.json"
    if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
      fail "source contract accepted a trailing newline in $manifest_identifier"
    fi
    grep -Fq "source contract manifest is malformed" "$fixture/self-test.out" \
      || fail "trailing newline in $manifest_identifier did not fail manifest validation"
    rm -r "$fixture"
  done

  for invalid_behavior_version in null '"3"' 2; do
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT HUP INT TERM
    mkdir -p "$fixture/.github"
    cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
    jq --argjson version "$invalid_behavior_version" \
      '.gateBehaviorContractVersion = $version' \
      "$source_contract" >"$fixture/.touchstone-source-contract.json"
    if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
      fail "source contract accepted gate behavior contract version $invalid_behavior_version"
    fi
    grep -Fq "source contract manifest is malformed" "$fixture/self-test.out" \
      || fail "invalid gate behavior contract version did not fail manifest validation"
    rm -r "$fixture"
  done

  for validation_mutation in missing-pull-request quoted-empty-pr pr-closed pr-filtered merge-group-destroyed quoted-write job-write-all; do
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT HUP INT TERM
    mkdir -p "$fixture/.github"
    cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
    cp "$source_contract" "$fixture/.touchstone-source-contract.json"
    case "$validation_mutation" in
      missing-pull-request)
        sed '/^  pull_request:$/d' "$fixture/$status_publisher" >"$fixture/validate.next"
        ;;
      quoted-empty-pr)
        sed 's/^  pull_request:$/  pull_request: ""/' "$fixture/$status_publisher" >"$fixture/validate.next"
        ;;
      pr-closed)
        sed 's/^  pull_request:$/  pull_request:\
    types: [closed]/' "$fixture/$status_publisher" >"$fixture/validate.next"
        ;;
      pr-filtered)
        sed 's/^  pull_request:$/  pull_request:\
    branches: [release]/' "$fixture/$status_publisher" >"$fixture/validate.next"
        ;;
      merge-group-destroyed)
        sed 's/types: \[checks_requested\]/types: [destroyed]/' "$fixture/$status_publisher" >"$fixture/validate.next"
        ;;
      quoted-write)
        sed 's/^  contents: read$/  contents: "write"/' "$fixture/$status_publisher" >"$fixture/validate.next"
        ;;
      job-write-all)
        sed '/^    runs-on:/i\
    permissions: write-all' "$fixture/$status_publisher" >"$fixture/validate.next"
        ;;
    esac
    mv "$fixture/validate.next" "$fixture/$status_publisher"
    if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
      fail "source contract accepted validation mutation $validation_mutation"
    fi
    rm -r "$fixture"
  done

  for behavior_mutation in commented-checksum moving-evaluator-ref bypass-coordinate-validation missing-review-scope missing-delivery-scope; do
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT HUP INT TERM
    mkdir -p "$fixture/.github"
    cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
    cp "$source_contract" "$fixture/.touchstone-source-contract.json"
    mutation_workflow="$fixture/.github/workflows/review-gate.yml"
    case "$behavior_mutation" in
      commented-checksum)
        awk '$0 == "          echo \"${evaluator_sha256}  $RUNNER_TEMP/evaluate-v3.jq\" | sha256sum --check --strict" { print "          : # checksum disabled"; next } { print }' \
          "$fixture/.github/workflows/review-gate.yml" >"$fixture/review-gate.next"
        ;;
      moving-evaluator-ref)
        # shellcheck disable=SC2016
        sed 's#/${touchstone_revision}/.github/review-gate/#/main/.github/review-gate/#' \
          "$fixture/.github/workflows/review-gate.yml" >"$fixture/review-gate.next"
        ;;
      bypass-coordinate-validation)
        # shellcheck disable=SC2016
        sed 's#^          fetch_pull_request .*#          gh api "repos/$REPO/pulls/$number" >"$tmp/pr.json"#' \
          "$fixture/.github/workflows/review-gate.yml" >"$fixture/review-gate.next"
        ;;
      missing-review-scope)
        sed '/^  issues: read$/d' "$mutation_workflow" >"$fixture/review-gate.next"
        ;;
      missing-delivery-scope)
        mutation_workflow="$fixture/.github/workflows/delivery-evidence.yml"
        sed '/^  pull-requests: read$/d' "$mutation_workflow" >"$fixture/review-gate.next"
        ;;
    esac
    mv "$fixture/review-gate.next" "$mutation_workflow"
    if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
      fail "source contract accepted behavior mutation $behavior_mutation"
    fi
    rm -r "$fixture"
  done

  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT HUP INT TERM
  mkdir -p "$fixture/.github"
  cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
  sed 's/^    name: source contract$/    name: source-contract/' \
    "$fixture/$status_publisher" >"$fixture/status-publisher.next"
  mv "$fixture/status-publisher.next" "$fixture/$status_publisher"
  unnamed_workflow=".github/workflows/unnamed-duplicate.yml"
  printf '%s\n' \
    'name: unnamed duplicate' \
    'on: pull_request' \
    'jobs:' \
    '  source-contract:' \
    '    runs-on: ubuntu-latest' \
    '    steps: []' >"$fixture/$unnamed_workflow"
  jq --arg context source-contract --arg path "$unnamed_workflow" \
    '.requiredStatusCheck = $context | .workflowPaths += [$path]' \
    "$source_contract" >"$fixture/.touchstone-source-contract.json"
  if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
    fail "source contract accepted an unnamed duplicate status publisher"
  fi
  if ! grep -Fq "duplicates required status 'source-contract'" "$fixture/self-test.out"; then
    cat "$fixture/self-test.out" >&2
    fail "unnamed duplicate did not fail for GitHub's effective job name"
  fi
  rm -r "$fixture"
fi

if [ "${TOUCHSTONE_CONTRACT_SELF_TEST:-0}" != 1 ]; then
  echo "==> a pull request with no driver still reaches the fallback"
  authorless_fixture="$(mktemp -d)"
  awk '
    /touchstone:provider-state:start/ { copying = 1; next }
    /touchstone:provider-state:end/ { copying = 0 }
    copying { sub(/^          /, ""); print }
  ' "$review_gate" >"$authorless_fixture/state.sh"

  check_authorless() {
    # $1 expected (yes|no), $2 pr.json contents, $3 label
    (
      tmp="$authorless_fixture"; printf '%s' "$2" >"$tmp/pr.json"
      # shellcheck source=/dev/null
      . "$authorless_fixture/state.sh"
      if authorless_pull_request; then actual=yes; else actual=no; fi
      [ "$actual" = "$1" ] || exit 1
    ) || fail "authorless_pull_request misread '$3' (expected $1)"
    echo "  OK: $3"
  }

  check_authorless yes '{"user":{"login":"dependabot[bot]","type":"Bot"}}' \
    "a Bot-authored pull request has no driver to request review"
  check_authorless yes '{"user":{"login":"renovate[bot]","type":"User"}}' \
    "a [bot] login counts even when the type does not say Bot"
  check_authorless no '{"user":{"login":"henrymodisett","type":"User"}}' \
    "a person-authored pull request still owes a review request"
  check_authorless no '{}' \
    "missing author data is not treated as authorless"
  rm -r "$authorless_fixture"

  echo "==> provider unavailability is an observed state, not an elapsed clock"
  state_fixture="$(mktemp -d)"
  awk '
    /touchstone:provider-state:start/ { copying = 1; next }
    /touchstone:provider-state:end/ { copying = 0 }
    copying { sub(/^          /, ""); print }
  ' "$review_gate" >"$state_fixture/state.sh"

  check_provider_state() {
    # $1 expected (yes|no), $2 evidence json, $3 case name
    (
      tmp="$state_fixture"; printf '%s' "$2" >"$tmp/evidence.json"
      # shellcheck source=/dev/null
      . "$state_fixture/state.sh"
      if provider_unavailable; then actual=yes; else actual=no; fi
      [ "$actual" = "$1" ] || exit 1
    ) || fail "provider_unavailable misread '$3' (expected $1)"
    echo "  OK: $3"
  }

  trusted='"trustedAuthors":["bot"]'
  quota='You have reached your Codex usage limits for code reviews.'

  check_provider_state yes \
    "{$trusted,\"issueComments\":[{\"user\":{\"login\":\"bot\"},\"created_at\":\"2026-01-02\",\"body\":\"$quota\"}],\"reviews\":[]}" \
    "a current notice from a trusted author is unavailability"

  check_provider_state no \
    "{$trusted,\"issueComments\":[{\"user\":{\"login\":\"stranger\"},\"created_at\":\"2026-01-02\",\"body\":\"$quota\"}],\"reviews\":[]}" \
    "an untrusted author cannot declare the provider down"

  check_provider_state no \
    "{$trusted,\"issueComments\":[{\"user\":{\"login\":\"bot\"},\"created_at\":\"2026-01-01\",\"body\":\"$quota\"}],\"reviews\":[{\"user\":{\"login\":\"bot\"},\"submitted_at\":\"2026-01-02\",\"body\":\"Reviewed commit: abc\"}]}" \
    "a later verdict supersedes an earlier notice"

  check_provider_state yes \
    "{$trusted,\"issueComments\":[{\"user\":{\"login\":\"bot\"},\"created_at\":\"2026-01-03\",\"body\":\"$quota\"}],\"reviews\":[{\"user\":{\"login\":\"bot\"},\"submitted_at\":\"2026-01-02\",\"body\":\"Reviewed commit: abc\"}]}" \
    "a notice after the last verdict is current"

  check_provider_state no \
    "{$trusted,\"issueComments\":[],\"reviews\":[]}" \
    "silence is not unavailability"

  rm -r "$state_fixture"

  echo "==> the fallback reviewer fails closed"
  fallback_fixture="$(mktemp -d)"
  awk '
    /touchstone:review-fallback:start/ { copying = 1; next }
    /touchstone:review-fallback:end/ { copying = 0 }
    copying { sub(/^          /, ""); print }
  ' "$review_gate" >"$fallback_fixture/fallback.sh"

  # Only an explicit empty finding set may return 0. Every other outcome must
  # leave the gate exactly as it behaved before the fallback existed.
  run_fallback_case() {
    # $1 case name, $2 http code, $3 response body, $4 diff contents
    (
      tmp="$fallback_fixture/evidence"; mkdir -p "$tmp"
      printf '0\n' >"$tmp/rest-request-count"
      RUNNER_TEMP="$fallback_fixture"; REPO="o/r"; number=1; event_mode=pull_request
      REST_REQUEST_LIMIT=12
        FALLBACK_ENDPOINT="https://example.invalid"; FALLBACK_MODEL=m; FALLBACK_PLUGIN=p
      FALLBACK_COST_TIER=low; FALLBACK_MAX_INPUT_BYTES=100000
      FALLBACK_MAX_COMPLETION_TOKENS=16; FALLBACK_MAX_PROMPT_PRICE=1
      FALLBACK_MAX_COMPLETION_PRICE=1; FALLBACK_CONNECT_TIMEOUT=1; FALLBACK_REQUEST_TIMEOUT=1
      printf 'prompt\n' >"$fallback_fixture/review-prompt.md"
      printf '%s' "$4" >"$fallback_fixture/diff-src"
      rest_api() {
        case "$1" in
          *compare*) cat "$fallback_fixture/diff-src" ;;
          *comments*) return 0 ;;
        esac
      }
      CASE_HTTP="$2"; CASE_BODY="$3"
      curl() {
        local out="" prev=""
        for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
        [ -n "$out" ] && printf '%s' "$CASE_BODY" >"$out"
        printf '%s' "$CASE_HTTP"
      }
      # shellcheck source=/dev/null
      . "$fallback_fixture/fallback.sh"
      fallback_review abc123 def456 >/dev/null 2>&1
    )
  }

  clean_body='{"choices":[{"message":{"content":"{\"summary\":\"ok\",\"findings\":[]}"}}]}'
  finding_body='{"choices":[{"message":{"content":"{\"summary\":\"x\",\"findings\":[{\"severity\":\"P1\",\"file\":\"a\",\"line\":1,\"title\":\"t\",\"body\":\"b\"}]}"}}]}'

  if ! ( export OPENROUTER_API=k; run_fallback_case clean 200 "$clean_body" "diff --git a b" ); then
    fail "fallback reviewer rejected an explicit clean verdict"
  fi
  echo "  OK: an explicit empty finding set passes"

  for case_name in \
    "findings|200|$finding_body|diff --git a b" \
    "malformed|200|{\"choices\":[{\"message\":{\"content\":\"not json\"}}]}|diff --git a b" \
    "no-content|200|{\"choices\":[]}|diff --git a b" \
    "http-500|500|{}|diff --git a b" \
    "empty-diff|200|$clean_body|"
  do
    IFS='|' read -r name code body diff <<<"$case_name"
    if ( export OPENROUTER_API=k; run_fallback_case "$name" "$code" "$body" "$diff" ); then
      fail "fallback reviewer passed the gate on '$name'"
    fi
    echo "  OK: $name is refused"
  done

  # An empty completion is retried exactly once: openrouter/auto picks a model
  # per request, and the billed request already produced nothing.
  (
    tmp="$fallback_fixture/evidence"; mkdir -p "$tmp"
    printf '0\n' >"$tmp/rest-request-count"
    RUNNER_TEMP="$fallback_fixture"; REPO="o/r"; number=1; event_mode=pull_request
    REST_REQUEST_LIMIT=12; OPENROUTER_API=k
    FALLBACK_ENDPOINT="https://example.invalid"; FALLBACK_MODEL=m; FALLBACK_PLUGIN=p
    FALLBACK_COST_TIER=low; FALLBACK_MAX_INPUT_BYTES=100000
    FALLBACK_MAX_COMPLETION_TOKENS=16; FALLBACK_MAX_PROMPT_PRICE=1
    FALLBACK_MAX_COMPLETION_PRICE=1; FALLBACK_CONNECT_TIMEOUT=1; FALLBACK_REQUEST_TIMEOUT=1
    printf 'prompt\n' >"$fallback_fixture/review-prompt.md"
    rest_api() { case "$1" in *compare*) printf 'diff --git a b\n' ;; *comments*) return 0 ;; esac; }
    printf '0\n' >"$fallback_fixture/attempts"
    curl() {
      local out="" prev="" n
      for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
      n=$(( $(cat "$fallback_fixture/attempts") + 1 )); printf '%s\n' "$n" >"$fallback_fixture/attempts"
      if [ "$n" -eq 1 ]; then
        [ -n "$out" ] && printf '%s' '{"model":"m","choices":[{"message":{"content":""},"finish_reason":"stop"}]}' >"$out"
      else
        [ -n "$out" ] && printf '%s' '{"choices":[{"message":{"content":"{\"summary\":\"ok\",\"findings\":[]}"}}]}' >"$out"
      fi
      printf '200'
    }
    # shellcheck source=/dev/null
    . "$fallback_fixture/fallback.sh"
    fallback_review abc123 def456 >/dev/null 2>&1 || exit 1
    [ "$(cat "$fallback_fixture/attempts")" = "2" ] || exit 1
  ) || fail "an empty completion was not retried into a usable verdict"
  echo "  OK: an empty completion is retried once and can then succeed"

  # The gate is read-only and cannot open review threads, so the severity bar
  # is applied here: P0/P1 close the gate, P2/P3 are reported without blocking.
  p2_body='{"choices":[{"message":{"content":"{\"summary\":\"x\",\"findings\":[{\"severity\":\"P2\",\"file\":\"a\",\"line\":1,\"title\":\"t\",\"body\":\"b\"}]}"}}]}'
  p3_body='{"choices":[{"message":{"content":"{\"summary\":\"x\",\"findings\":[{\"severity\":\"P3\",\"file\":\"a\",\"line\":1,\"title\":\"t\",\"body\":\"b\"}]}"}}]}'
  p0_body='{"choices":[{"message":{"content":"{\"summary\":\"x\",\"findings\":[{\"severity\":\"P0\",\"file\":\"a\",\"line\":1,\"title\":\"t\",\"body\":\"b\"}]}"}}]}'
  mixed_body='{"choices":[{"message":{"content":"{\"summary\":\"x\",\"findings\":[{\"severity\":\"P2\",\"file\":\"a\",\"line\":1,\"title\":\"t\",\"body\":\"b\"},{\"severity\":\"P1\",\"file\":\"c\",\"line\":2,\"title\":\"u\",\"body\":\"v\"}]}"}}]}'

  for row in "P2 only|$p2_body|open" "P3 only|$p3_body|open" "P0|$p0_body|closed" "P1 with a P2|$mixed_body|closed"; do
    IFS='|' read -r label rbody expect <<<"$row"
    if ( export OPENROUTER_API=k; run_fallback_case "$label" 200 "$rbody" "diff --git a b" ); then actual=open; else actual=closed; fi
    [ "$actual" = "$expect" ] || fail "severity bar: '$label' left the gate $actual, expected $expect"
    echo "  OK: $label leaves the gate $expect"
  done

  # A 200 carrying an error is a provider failure, not model variance: it must
  # be refused and named, not retried as an empty completion.
  err_body='{"error":{"message":"rate limit exceeded"}}'
  if ( export OPENROUTER_API=k; run_fallback_case "error-in-200" 200 "$err_body" "diff --git a b" ); then
    fail "a 200 carrying a provider error opened the gate"
  fi
  echo "  OK: a provider error inside a 200 is refused"

  if ( unset OPENROUTER_API; run_fallback_case nocred 200 "$clean_body" "diff --git a b" ); then
    fail "fallback reviewer passed the gate with no credential configured"
  fi
  echo "  OK: a missing credential never passes"
  rm -r "$fallback_fixture"
fi

echo "workflow contract passed"
