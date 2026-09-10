#!/usr/bin/env bash
# validate's hosted-runner check (AUT-1592): refuse a GitHub-hosted macOS or
# Windows runner, and a setting-derived selector that does not require the
# self-hosted label, in any consumer workflow. The program under test is the
# one embedded in validate.yml's "Refuse GitHub-hosted macOS and Windows
# runners" step, extracted here byte for byte.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "  OK: $*"; }

PROGRAM="$TMP/check.rb"
ruby -rpsych -e '
  workflow = Psych.safe_load(File.read(ARGV[0]), aliases: true)
  step = workflow.fetch("jobs").fetch("validate").fetch("steps").find { |s| s["name"] == ARGV[1] }
  abort "validate has no step named #{ARGV[1]}" unless step
  program = step.fetch("run")[/<<'\''RUBY'\''\n(.*?)^RUBY$/m, 1]
  abort "the step embeds no RUBY heredoc" unless program
  File.write(ARGV[2], program)
' "$ROOT/.github/workflows/validate.yml" "Refuse GitHub-hosted macOS and Windows runners" "$PROGRAM" \
  || fail "could not extract the hosted-runner program from validate.yml"
CHECK="$TMP/check.sh"
printf '#!/usr/bin/env bash\nexec ruby -rpsych %q "$@"\n' "$PROGRAM" >"$CHECK"

# Fixtures are written by heredoc into a directory made first: a heredoc
# inside $(...) is misparsed by some bash versions when its text holds a quote.
project() { mktemp -d "$TMP/project.XXXXXX"; }

# workflow DIR [FILE]: write stdin to DIR/.github/workflows/FILE.
workflow() {
  mkdir -p "$1/.github/workflows"
  cat >"$1/.github/workflows/${2:-ci.yml}"
}

# expect RC LABEL DIR [TEXT...]: the check exits RC on DIR and prints each TEXT.
expect() {
  local want="$1" label="$2" dir="$3" out rc text
  shift 3
  set +e
  out="$(bash "$CHECK" "$dir" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq "$want" ] || fail "$label: expected exit $want, got $rc: $out"
  for text in "$@"; do
    grep -Fq -- "$text" <<<"$out" || fail "$label: output lacks '$text': $out"
  done
  ok "$label"
}

echo "==> hosted images are refused wherever a workflow names them"
dir="$(project)"
workflow "$dir" <<'EOF'
name: ci
on: pull_request
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF
expect 0 "a Linux runner passes" "$dir" "1 workflow file(s)"

dir="$(project)"
workflow "$dir" <<'EOF'
name: ci
on: pull_request
jobs:
  test:
    runs-on: macos-14
    steps:
      - run: echo ok
EOF
expect 1 "a hosted macOS label is refused at its line" "$dir" "ci.yml:5:" "'macos-14'"

dir="$(project)"
workflow "$dir" build.yaml <<'EOF'
jobs:
  build:
    runs-on: windows-latest-8-cores
EOF
expect 1 "a larger Windows runner in a .yaml file is refused" "$dir" "build.yaml:3:" "'windows-latest-8-cores'"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
EOF
expect 1 "a hosted image in a matrix os list is refused" "$dir" "ci.yml:5:" "'macos-latest'"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on:
      - macos-15-xlarge
EOF
expect 1 "a hosted image in a multi-line runs-on list is refused" "$dir" "ci.yml:4:" "'macos-15-xlarge'"

# vesper's and hesperus's main branches before AUT-1582/AUT-1584 have this shape.
dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ github.event_name != 'pull_request' && 'ubuntu-latest' || 'macos-26' }}
EOF
expect 1 "a hosted image as an expression's fallback is refused" "$dir" "'macos-26'"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: MACOS-14
EOF
expect 1 "an image's name matches in any case" "$dir" "'macos-14'"

dir="$(project)"
workflow "$dir" <<'EOF'
# The macOS job once ran on macos-26; it never does now.
jobs:
  test:
    runs-on: ubuntu-latest # not windows-latest, not macos-latest
    steps:
      # a hosted macos-15 image is never the fallback
      - run: echo ok
EOF
expect 0 "comments that mention an image do not trip the check" "$dir"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: [self-hosted, studio-macos-14]
EOF
expect 0 "a self-hosted label that contains an image's name is not a hosted image" "$dir"

echo "==> a setting-derived selector must require the self-hosted label"
# hesperus's fix/no-hosted-macos shape: the setting's value goes straight to runs-on.
dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ vars.MACOS_RUNNER == '' && 'ubuntu-latest' || vars.MACOS_RUNNER }}
EOF
expect 1 "a setting's value used alone as the runner is refused" "$dir" "ci.yml:3:" "self-hosted"

# AUT-1588's shape.
dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ vars.MACOS_RUNNER == '' && 'ubuntu-latest' || fromJSON(format('["self-hosted","{0}"]', vars.MACOS_RUNNER)) }}
EOF
expect 0 "a macOS setting with the self-hosted label required passes" "$dir"

# AUT-1595's shape for these required workflows.
dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  validate:
    runs-on: ${{ vars.LINUX_RUNNER && fromJSON(format('["self-hosted","{0}"]', vars.LINUX_RUNNER)) || 'ubuntu-latest' }}
EOF
expect 0 "the LINUX_RUNNER selector passes" "$dir"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on:
      - self-hosted
      # the Mac mini's label comes from the setting
      - ${{ vars.MACOS_RUNNER }}
    steps:
      - run: echo ok
EOF
expect 0 "a multi-line list that requires self-hosted passes" "$dir"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on:
      - macOS
      - ${{ vars.MACOS_RUNNER }}
    steps:
      - run: echo ok
EOF
expect 1 "a multi-line list without self-hosted is refused" "$dir" "ci.yml:3:" "self-hosted"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    steps: []
    runs-on:
      - ${{ vars.MACOS_RUNNER }}
EOF
expect 1 "a selector that ends the file is still judged" "$dir" "ci.yml:4:"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ubuntu-latest
    env:
      MACOS_RUNNER: ${{ vars.MACOS_RUNNER }}
EOF
expect 0 "a setting read into env is not a selector" "$dir"

echo "==> every form GitHub accepts is the same to the check (touchstone#1189)"
dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ vars['MACOS_RUNNER'] }}
EOF
expect 1 "index syntax reads a setting too" "$dir" "ci.yml:3:" "self-hosted"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on:
    - ${{ vars.MACOS_RUNNER }}
EOF
expect 1 "an indentationless sequence is read whole" "$dir" "ci.yml:3:"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on:
    - self-hosted
    - ${{ vars.MACOS_RUNNER }}
EOF
expect 0 "an indentationless sequence that requires self-hosted passes" "$dir"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    "runs-on": ${{ vars.MACOS_RUNNER }}
EOF
expect 1 "a quoted runs-on key is the same key" "$dir" "ci.yml:3:"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: [SELF-HOSTED, "${{ vars.MACOS_RUNNER }}"]
EOF
expect 0 "labels compare case-insensitively, as GitHub compares them" "$dir"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on:
      group: mac-minis
      labels: [self-hosted, "${{ vars.MACOS_RUNNER }}"]
EOF
expect 0 "a group-and-labels mapping that requires self-hosted passes" "$dir"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on:
      group: mac-minis
      labels: "${{ vars.MACOS_RUNNER }}"
EOF
expect 1 "a group-and-labels mapping without self-hosted is refused" "$dir" "ci.yml:3:"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    env:
      RUNNER: &runner "${{ vars.MACOS_RUNNER }}"
    runs-on: *runner
EOF
expect 1 "a selector reached through a YAML alias is resolved" "$dir" "ci.yml:5:"

echo "==> every setting reference is judged on its own"
# vesper#1255's and hesperus#354's selectors: the LINUX_RUNNER branch is
# wrapped, the MACOS_RUNNER branch beside it is not. One wrapped branch must
# never excuse a bare one.
dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ github.event_name == 'merge_group' && fromJSON(format('["self-hosted","{0}"]', vars.LINUX_RUNNER)) || vars.MACOS_RUNNER }}
EOF
expect 1 "a wrapped branch does not excuse a bare setting beside it" "$dir" "ci.yml:3:" "not wrapped"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  swift:
    runs-on: ${{ (vars.MACOS_RUNNER == '' || needs.scope.outputs.swift == 'false') && (vars.LINUX_RUNNER && fromJSON(format('["self-hosted","{0}"]', vars.LINUX_RUNNER)) || 'ubuntu-latest') || vars.MACOS_RUNNER }}
EOF
expect 1 "hesperus#354's selector is refused for its bare macOS branch" "$dir" "ci.yml:3:"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ vars.MACOS_RUNNER || 'self-hosted' }}
EOF
expect 1 "naming self-hosted as a fallback does not wrap the setting" "$dir" "ci.yml:3:"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ fromJSON(format('["{0}"]', vars.MACOS_RUNNER)) }}
EOF
expect 1 "a format that leaves out self-hosted does not wrap the setting" "$dir" "ci.yml:3:"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ startsWith(vars.MACOS_RUNNER, 'ci-') && !contains('none,off', vars.MACOS_RUNNER) && fromJSON(format('["self-hosted","{0}"]', vars.MACOS_RUNNER)) || 'ubuntu-latest' }}
EOF
expect 0 "settings used only as conditions, then wrapped, pass" "$dir"

dir="$(project)"
workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ${{ !vars.MACOS_RUNNER && 'ubuntu-latest' || fromJSON(format('["SELF-HOSTED","{0}"]', vars['MACOS_RUNNER'])) }}
EOF
expect 0 "a negated guard and a wrapped index reference pass" "$dir"

echo "==> every file is read, and each finding names its own file"
dir="$(project)"
workflow "$dir" a.yml <<'EOF'
jobs:
  test:
    runs-on:
      - ${{ vars.MACOS_RUNNER }}
EOF
workflow "$dir" b.yml <<'EOF'
jobs:
  test:
    runs-on: windows-2022
EOF
workflow "$dir" c.yml <<'EOF'
jobs:
  test:
    runs-on: ubuntu-latest
EOF
expect 1 "findings in two files are both reported" "$dir" "a.yml:3:" "b.yml:3:" "'windows-2022'"
set +e
out="$(bash "$CHECK" "$dir" 2>&1)"
set -e
if grep -Fq 'c.yml:' <<<"$out"; then
  fail "a clean file was blamed for another file's finding: $out"
fi
ok "a clean file beside two refused ones is not blamed"

echo "==> inputs and read failures"
dir="$(project)"
workflow "$dir" <<'EOF'
jobs: [unclosed
EOF
expect 1 "a workflow that does not parse is refused, not skipped" "$dir" "does not parse"
expect 0 "a project without workflows has nothing to check" "$(project)" "nothing to check"
expect 2 "a missing project directory is a usage error" "$TMP/absent" "does not exist"
if [ "$(id -u)" -ne 0 ]; then
  dir="$(project)"
  workflow "$dir" <<'EOF'
jobs:
  test:
    runs-on: ubuntu-latest
EOF
  chmod 000 "$dir/.github/workflows"
  expect 2 "an unreadable workflows directory is an error, never a pass" "$dir" "cannot read"
  chmod 755 "$dir/.github/workflows"
fi
set +e
bash "$CHECK" "$TMP" "$TMP" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "two arguments should be a usage error, got exit $rc"
ok "two arguments are a usage error"

echo "==> this repository's own workflows"
expect 0 "touchstone-workflows names no hosted macOS or Windows runner" "$ROOT"

echo "hosted-runner check passed"
