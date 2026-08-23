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

assert_count 1 'name: validate \(ubuntu-latest\)'
assert_count 2 'uses: actions/checkout@[0-9a-f]{40}'
assert_count 1 'touchstone_revision="[0-9a-f]{40}"'
assert_count 1 'touchstone_sha256="[0-9a-f]{64}"'
assert_count 1 'raw\.githubusercontent\.com/autumngarage/touchstone/'
assert_count 1 'sha256sum --check --strict'
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

# The repository policy requires one literal status context. Keep that name in
# a machine-readable manifest so the policy engine can compare its desired rule
# with its one publisher instead of relying on an ambiguous duplicate context.
command -v jq >/dev/null 2>&1 || fail "jq is required to validate the source contract"
jq -e '
  . as $contract
  | .contractVersion == 1
  and (.requiredStatusCheck | type == "string" and length > 0)
  and (.sourceRepository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
  and (.statusJob | type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$"))
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
for gate in "$repo_root"/.github/workflows/*.yml "$repo_root"/.github/workflows/*.yaml; do
  [ -f "$gate" ] || continue
  repository_workflow_count=$((repository_workflow_count + 1))
  relative_gate="${gate#"$repo_root"/}"
  jq -e --arg path "$relative_gate" '.workflowPaths | index($path) != null' "$source_contract" >/dev/null \
    || fail "$relative_gate: workflow is absent from the source contract manifest"
  published_jobs="$(awk -v context="$required_status_check" '
    /^  [^ ]+:[[:space:]]*$/ {
      job = $0
      sub(/^  /, "", job)
      sub(/:[[:space:]]*$/, "", job)
      next
    }
    $0 == "    name: " context { print job }
  ' "$gate")"
  if [ -n "$published_jobs" ]; then
    [ "$relative_gate" = "$status_publisher" ] \
      || fail "$relative_gate: duplicates required status '$required_status_check' owned by $status_publisher"
    [ "$published_jobs" = "$status_job" ] \
      || fail "$relative_gate: required status '$required_status_check' must be published only by job $status_job"
    awk -v repository="$source_repository" -v job="$status_job" '
      $0 == "  " job ":" { in_source_contract = 1; next }
      in_source_contract && /^  [^ ]/ { in_source_contract = 0 }
      in_source_contract && $0 == "    if: github.repository == \047" repository "\047" { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$gate" || fail "$relative_gate: status publisher is not guarded to $source_repository"
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
  printf '%s\n' \
    '  duplicate-source-contract:' \
    '    name: source contract' \
    '    runs-on: ubuntu-latest' \
    '    steps: []' >>"$fixture/$status_publisher"
  if TOUCHSTONE_CONTRACT_ROOT="$fixture" TOUCHSTONE_CONTRACT_SELF_TEST=1 bash "$0" >"$fixture/self-test.out" 2>&1; then
    fail "source contract accepted a duplicate status publisher under another job ID"
  fi
  grep -Fq "must be published only by job $status_job" "$fixture/self-test.out" \
    || fail "duplicate status publisher did not fail for the expected invariant"
fi

echo "workflow contract passed"
