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

echo "==> behavior-v1 workflows use root PR/queue triggers and read-only permissions"
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
    %w[pull_request merge_group].each { |event| one.call(triggers, event, "on") }

    permissions = pairs.call(one.call(root, "permissions", "workflow"), "permissions")
    raise "permissions must not be empty" if permissions.empty?
    permissions.each do |key, value|
      name = scalar.call(key, "permission name")
      level = scalar.call(value, "permission #{name}")
      raise "permission #{name} must be read-only" unless level == "read"
    end

    jobs = pairs.call(one.call(root, "jobs", "workflow"), "jobs")
    jobs.each do |job_key, configuration|
      job = scalar.call(job_key, "job ID")
      fields = pairs.call(configuration, "job #{job}")
      if fields.any? { |key, _| scalar.call(key, "job #{job} key") == "permissions" }
        raise "job #{job} must not override permissions"
      end
    end
  ' "$gate" || fail "$gate: violates behavior-v1 trigger or permission invariants"
done
echo "  OK: triggers and effective permissions are structurally bound"

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

echo "==> review-gate collects effective permission once per potential driver author"
collector_fixture="$(mktemp -d)"
trap 'rm -rf "$collector_fixture"' EXIT HUP INT TERM
awk '
  /touchstone:permission-collector:start/ { copying = 1; next }
  /touchstone:permission-collector:end/ { copying = 0 }
  copying { sub(/^          /, ""); print }
' "$review_gate" >"$collector_fixture/collector.sh"
# shellcheck source=/dev/null
source "$collector_fixture/collector.sh"
tmp="$collector_fixture/evidence"
# Used by the sourced production collector.
# shellcheck disable=SC2034
REPO=example/project
mkdir -p "$tmp"
mock_calls="$collector_fixture/calls"
: >"$mock_calls"

gh() {
  [ "$1" = api ] || return 99
  case "$2" in
    --paginate)
      case "$3" in
        *issues/*/comments*)
          printf '%s\n' \
            '[{"body":"@codex review","user":{"login":"admin"}},{"body":"ordinary discussion","user":{"login":"ignored"}}]' \
            '[{"body":" <!-- touchstone:review-answer id=7 -->","user":{"login":"writer"}},{"body":"@CODEX review again","user":{"login":"admin"}},{"body":"<!-- touchstone:review-answer id=8 -->","user":{"login":"outsider"}}]'
          ;;
        *pulls/*/comments*)
          printf '%s\n' \
            '[{"in_reply_to_id":7,"user":{"login":"writer"}},{"in_reply_to_id":null,"user":{"login":"finding"}}]' \
            '[{"in_reply_to_id":8,"user":{"login":"maintainer"}}]'
          ;;
        *) return 98 ;;
      esac
      ;;
    --include)
      login="${3%/permission}"
      login="${login##*/}"
      printf '%s\n' "$login" >>"$mock_calls"
      case "$login" in
        admin) permission="admin" ;;
        writer) permission="write" ;;
        maintainer) permission="maintain" ;;
        outsider)
          printf 'HTTP/2.0 404 Not Found\r\nContent-Type: application/json\r\n\r\n{"message":"Not Found"}\n'
          echo 'gh: Not Found (HTTP 404)' >&2
          return 1
          ;;
        denied)
          printf 'HTTP/2.0 403 Forbidden\r\nContent-Type: application/json\r\n\r\n{"message":"Forbidden"}\n'
          echo 'gh: Forbidden (HTTP 403)' >&2
          return 1
          ;;
        transport)
          echo 'gh: connection reset' >&2
          return 1
          ;;
        *) return 97 ;;
      esac
      printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"permission":"%s"}\n' "$permission"
      ;;
    *) return 96 ;;
  esac
}

api_array 'repos/example/project/issues/1/comments?per_page=100' "$tmp/issues.json"
api_array 'repos/example/project/pulls/1/comments?per_page=100' "$tmp/review-comments.json"
collect_author_permissions "$tmp/issues.json" "$tmp/review-comments.json" "$tmp/author-permissions.json"
jq -e '. == {admin:"admin", maintainer:"maintain", outsider:"none", writer:"write"}' \
  "$tmp/author-permissions.json" >/dev/null || fail "permission map lost a page, driver path, or expected 404"
for login in admin writer maintainer outsider; do
  [ "$(grep -Fxc "$login" "$mock_calls")" -eq 1 ] || fail "$login permission was not looked up exactly once"
done
if grep -Eq '^(ignored|finding)$' "$mock_calls"; then
  fail "ordinary discussion or a top-level finding triggered a permission lookup"
fi

printf '[{"body":"@codex review","user":{"login":"denied"}}]\n' >"$tmp/issues.json"
printf '[]\n' >"$tmp/review-comments.json"
if collect_author_permissions "$tmp/issues.json" "$tmp/review-comments.json" "$tmp/denied.json" 2>"$tmp/denied.err"; then
  fail "an authorization failure did not fail permission collection closed"
fi
grep -Fq "HTTP 403" "$tmp/denied.err" || fail "authorization failure lost its HTTP context"

printf '[{"body":"@codex review","user":{"login":"transport"}}]\n' >"$tmp/issues.json"
if collect_author_permissions "$tmp/issues.json" "$tmp/review-comments.json" "$tmp/transport.json" 2>"$tmp/transport.err"; then
  fail "a transport failure did not fail permission collection closed"
fi
grep -Fq "transport failure" "$tmp/transport.err" || fail "transport failure lost its diagnostic context"
rm -rf "$collector_fixture"
trap - EXIT HUP INT TERM
echo "  OK: pagination, unique lookup, non-collaborators, and failures are explicit"

# The repository policy requires one literal status context. Keep that name in
# a machine-readable manifest so the policy engine can compare its desired rule
# with its one publisher instead of relying on an ambiguous duplicate context.
command -v jq >/dev/null 2>&1 || fail "jq is required to validate the source contract"
command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse workflow YAML"
jq -e '
  . as $contract
  | .contractVersion == 1
  and .gateBehaviorContractVersion == 1
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

  for invalid_behavior_version in null '"1"' 2; do
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

  for validation_mutation in missing-pull-request quoted-write job-write-all; do
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT HUP INT TERM
    mkdir -p "$fixture/.github"
    cp -R "$repo_root/.github/workflows" "$fixture/.github/workflows"
    cp "$source_contract" "$fixture/.touchstone-source-contract.json"
    case "$validation_mutation" in
      missing-pull-request)
        sed '/^  pull_request:$/d' "$fixture/$status_publisher" >"$fixture/validate.next"
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

echo "workflow contract passed"
