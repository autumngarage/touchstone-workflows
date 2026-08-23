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
command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse workflow YAML"
jq -e '
  . as $contract
  | .contractVersion == 1
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
      if job == ARGV.fetch(3) && name == ARGV.fetch(1)
        guards = fields.select { |key, _| key.value == "if" }
        raise "status publisher must declare one repository guard" unless guards.length == 1
        guard = scalar.call(guards.first.fetch(1), "status publisher guard")
        expected_guard = "github.repository == " + 39.chr + ARGV.fetch(2) + 39.chr
        raise "status publisher has the wrong repository guard" unless guard == expected_guard
      end
      puts job if name == ARGV.fetch(1)
    end
  ' "$gate" "$required_status_check" "$source_repository" "$status_job")"; then
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
fi

echo "workflow contract passed"
