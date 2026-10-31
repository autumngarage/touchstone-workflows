#!/usr/bin/env bash
set -euo pipefail

repo_root="${TOUCHSTONE_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
workflow="$repo_root/.github/workflows/delivery-evidence.yml"
manifest="$repo_root/.touchstone-source-contract.json"
fail() { echo "FAIL: evidence pin: $*" >&2; exit 1; }

jq -e '
  .contractVersion == 1
  and (.evidenceChecker | keys == ["path", "repository", "revision", "sha256"])
  and .evidenceChecker.repository == "autumngarage/touchstone"
  and .evidenceChecker.path == "scripts/check-delivery-evidence.sh"
  and (.evidenceChecker.revision | type == "string" and test("^[0-9a-f]{40}\\z"))
  and (.evidenceChecker.sha256 | type == "string" and test("^[0-9a-f]{64}\\z"))
' "$manifest" >/dev/null || fail "published checker coordinates are malformed"

# Parse the actual step: injecting correct test values alone would miss a
# workflow accidentally wired to the consumer's repository or commit.
# shellcheck disable=SC2016
ruby -rpsych -e '
  workflow = Psych.safe_load(File.read(ARGV[0]), permitted_classes: [], aliases: true)
  job = workflow.fetch("jobs").fetch("delivery-evidence")
  step = job.fetch("steps").find { |s| s["name"] == "Fetch pinned evaluator" }
  expected = {
    "SOURCE_REPOSITORY" => "${{ job.workflow_repository }}",
    "SOURCE_WORKFLOW_PATH" => "${{ job.workflow_file_path }}",
    "SOURCE_REVISION" => "${{ job.workflow_sha }}"
  }
  raise "source identity must be wired in step env" unless step.fetch("env") == expected
  raise "job context is unavailable in job env" if job.fetch("env", {}).values.any? { |v| v.include?("job.workflow_") }
' "$workflow" || fail "workflow source identity wiring is invalid"

# Recursive contract mutations need the declaration checks, not the fixture
# matrix again. Keep the existing self-test boundary.
[ "${TOUCHSTONE_CONTRACT_SELF_TEST:-0}" != 1 ] || exit 0
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/bin"
ruby -rpsych -e '
  steps = Psych.safe_load(File.read(ARGV[0]), permitted_classes: [], aliases: true).fetch("jobs").fetch("delivery-evidence").fetch("steps")
  File.write(ARGV[1], steps.find { |s| s["name"] == "Fetch pinned evaluator" }.fetch("run"))
  File.write(ARGV[2], steps.find { |s| s["name"] == "Verify recorded evidence" }.fetch("run"))
' "$workflow" "$fixture/fetch.sh" "$fixture/verify.sh"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "verified\\n" >>"$PIN_FIXTURE/executed"' >"$fixture/checker.sh"
checker_digest="$(shasum -a 256 "$fixture/checker.sh" | awk '{print $1}')"
jq --arg digest "$checker_digest" '.evidenceChecker.sha256 = $digest' "$manifest" >"$fixture/valid.json"
source_revision=1234567890123456789012345678901234567890
checker_revision="$(jq -r '.evidenceChecker.revision' "$manifest")"
cat >"$fixture/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url= output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    --retry|--retry-delay) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$PIN_FIXTURE/requests"
case "$url" in
  "https://raw.githubusercontent.com/autumngarage/touchstone-workflows/$EXPECTED_SOURCE_REVISION/.touchstone-source-contract.json")
    [ "${FAIL_DOWNLOAD:-}" != manifest ] || exit 22
    cp "$PIN_FIXTURE/manifest.json" "$output" ;;
  "https://raw.githubusercontent.com/autumngarage/touchstone/$EXPECTED_CHECKER_REVISION/scripts/check-delivery-evidence.sh")
    [ "${FAIL_DOWNLOAD:-}" != checker ] || exit 22
    cp "$PIN_FIXTURE/checker.sh" "$output" ;;
  *) echo "unexpected source URL: $url" >&2; exit 23 ;;
esac
SH
cat >"$fixture/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'fixture PR body\n'
SH
chmod +x "$fixture/bin/curl" "$fixture/bin/gh"
if [ "$(uname -s)" = Darwin ]; then
  # macOS sha256sum lacks GNU --strict; Perl shasum performs the same real
  # digest verification while accepting the workflow's Linux flags.
  printf '%s\n' '#!/usr/bin/env bash' 'exec shasum -a 256 "$@"' >"$fixture/bin/sha256sum"
  chmod +x "$fixture/bin/sha256sum"
fi
export PIN_FIXTURE="$fixture" EXPECTED_SOURCE_REVISION="$source_revision" EXPECTED_CHECKER_REVISION="$checker_revision"
export PATH="$fixture/bin:$PATH"

run_case() {
  local name="$1" expected="$2" requests="$3"
  shift 3
  rm -rf "$fixture/run"
  mkdir -p "$fixture/run"
  : >"$fixture/env"
  : >"$fixture/requests"
  rm -f "$fixture/executed"
  if env SOURCE_REPOSITORY=autumngarage/touchstone-workflows \
    SOURCE_WORKFLOW_PATH=.github/workflows/delivery-evidence.yml SOURCE_REVISION="$source_revision" \
    GITHUB_REPOSITORY=untrusted/consumer GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    RUNNER_TEMP="$fixture/run" GITHUB_ENV="$fixture/env" "$@" \
    bash "$fixture/fetch.sh" >"$fixture/result" 2>&1; then
    [ "$expected" = success ] || fail "$name accepted invalid source evidence"
    grep -Fxq "TOUCHSTONE_EVIDENCE_CHECKER_REVISION=$checker_revision" "$fixture/env" || fail "$name lost checker identity"
  else
    [ "$expected" = failure ] || { cat "$fixture/result" >&2; fail "$name failed"; }
    [ ! -s "$fixture/env" ] || fail "$name published an unverified checker"
  fi
  [ "$(wc -l <"$fixture/requests" | tr -d ' ')" = "$requests" ] || fail "$name fetched an unexpected source"
  [ ! -f "$fixture/executed" ] || fail "$name executed during fetch"
}

cp "$fixture/valid.json" "$fixture/manifest.json"
for event in pull_request merge_group; do
  run_case "$event" success 2 GITHUB_EVENT_NAME="$event"
  if [ "$event" = pull_request ]; then
    printf '{"pull_request":{"number":17}}\n' >"$fixture/event.json"
  else
    printf '{"merge_group":{"head_ref":"refs/heads/gh-readonly-queue/main/pr-17-%s"}}\n' "$source_revision" >"$fixture/event.json"
  fi
  env RUNNER_TEMP="$fixture/run" GITHUB_EVENT_NAME="$event" GITHUB_EVENT_PATH="$fixture/event.json" REPO=untrusted/consumer \
    bash "$fixture/verify.sh" || fail "$event verification did not consume fetched checker"
  [ "$(cat "$fixture/executed")" = verified ] || fail "$event checker did not run"
done
for invalid in SOURCE_REPOSITORY= SOURCE_REPOSITORY=untrusted/consumer SOURCE_WORKFLOW_PATH=other.yml SOURCE_REVISION=main SOURCE_REVISION=; do
  run_case "$invalid" failure 0 "$invalid"
done
for mutation in 'del(.evidenceChecker)' '.evidenceChecker = {}' '.evidenceChecker.repository = "untrusted/consumer"' '.evidenceChecker.path = "../checker.sh"' '.evidenceChecker.revision = "main"' '.evidenceChecker.revision += "\n"' '.evidenceChecker.sha256 = "invalid"' '.evidenceChecker.sha256 += "\n"' '.contractVersion = 2'; do
  jq "$mutation" "$fixture/valid.json" >"$fixture/manifest.json"
  run_case "$mutation" failure 1
done
printf 'not json\n' >"$fixture/manifest.json"
run_case malformed-json failure 1
cp "$fixture/valid.json" "$fixture/manifest.json"
run_case manifest-download failure 1 FAIL_DOWNLOAD=manifest
run_case checker-download failure 2 FAIL_DOWNLOAD=checker
jq '.evidenceChecker.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$fixture/valid.json" >"$fixture/manifest.json"
run_case checksum-mismatch failure 2
echo '  OK: evidence checker binds immutable workflow source, published coordinates and verified bytes'
