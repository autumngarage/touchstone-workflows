#!/usr/bin/env bash
# runner/macos-runner.sh (AUT-2013): a pool of macOS runner slots in one CI
# account. Slot 1 is the existing runner and is never re-registered; added
# slots copy its runner files but not its identity, register with the pool
# label, and start their own LaunchAgent; install is idempotent.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/runner/macos-runner.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "  OK: $*"; }

home="$tmp/Users"
calls="$tmp/calls"
: >"$calls"

# The account's existing runner: a configured slot 1 with its own identity
# and state beside the runner's files.
slot1="$home/ci/actions-runner"
mkdir -p "$slot1/bin" "$slot1/_work/job" "$slot1/_diag"
echo '{"agentName":"ci-studio"}' >"$slot1/.runner"
echo secret >"$slot1/.credentials"
echo secret >"$slot1/.credentials_rsaparams"
echo marker >"$slot1/.service"
echo '/opt/homebrew/bin:/usr/bin:/bin' >"$slot1/.path"
echo 'LANG=en_US.UTF-8' >"$slot1/.env"
echo runner >"$slot1/bin/Runner.Listener"
echo slot1-svc >"$slot1/svc.sh"
echo slot1-runsvc >"$slot1/runsvc.sh"
# The runner's config.sh as every slot receives it: registering writes the
# slot's .runner and its own svc.sh, as the real one does.
cat >"$slot1/config.sh" <<'EOF'
#!/usr/bin/env bash
printf 'config %s %s\n' "$(pwd)" "$*" >>"$FAKE_CALLS"
if [ "${1:-}" = remove ]; then rm -f .runner; exit 0; fi
[ -n "${FAKE_CONFIG_FAILS:-}" ] && exit 1
echo '{"agentName":"added"}' >.runner
cat >svc.sh <<'SVC'
#!/usr/bin/env bash
printf 'svc %s %s\n' "$(pwd)" "$*" >>"$FAKE_CALLS"
SVC
chmod +x svc.sh
EOF
chmod +x "$slot1/config.sh"

# Runs a command "as USER": records the user and runs it here.
as_user="$tmp/as-user"
cat >"$as_user" <<'EOF'
#!/usr/bin/env bash
printf 'as %s\n' "$1" >>"$FAKE_CALLS"
shift
exec "$@"
EOF
chmod +x "$as_user"

run() {
  env MACOS_RUNNER_HOME_ROOT="$home" MACOS_RUNNER_AS="$as_user" FAKE_CALLS="$calls" \
    "$@"
}

echo "==> arguments are checked before anything changes"
refused() { # what command...
  local what="$1"
  shift
  if run "$@" >/dev/null 2>&1; then fail "accepted $what"; fi
  ok "$what refused"
}
refused "zero slots" bash "$script" install ci 0
refused "a non-numeric slot count" bash "$script" install ci two
refused "an invalid user" bash "$script" install 'ci;x' 2
refused "a user with no home" bash "$script" install nobody 2
refused "removing slot 1" bash "$script" uninstall-slot ci 1

echo "==> a missing token leaves no half-made slot"
out="$(run bash "$script" install ci 2 2>&1)" && fail "added a slot without a token"
grep -q 'MACOS_RUNNER_TOKEN' <<<"$out" || fail "the missing-token refusal did not name the variable: $out"
[ ! -e "$home/ci/actions-runner-2" ] || fail "a refused install left a slot directory behind"
[ ! -s "$calls" ] || fail "a refused install ran commands: $(cat "$calls")"
ok "refused before any change"

echo "==> one slot means only the existing runner"
out="$(run bash "$script" install ci 1)"
grep -q 'slots 1..1 present for ci (0 added)' <<<"$out" || fail "one slot did not report slot 1 alone: $out"
! grep -q '^config' "$calls" || fail "slot 1 was re-registered"
ok "slot 1 is never re-registered"

echo "==> adding a slot copies the runner, not slot 1's identity"
: >"$calls"
out="$(run env MACOS_RUNNER_TOKEN=regtok bash "$script" install ci 3)"
for n in 2 3; do
  d="$home/ci/actions-runner-$n"
  [ -f "$d/.runner" ] || fail "slot $n is not registered"
  [ -f "$d/bin/Runner.Listener" ] || fail "slot $n lacks the runner's files"
  cmp -s "$d/.path" "$slot1/.path" || fail "slot $n does not share slot 1's .path"
  cmp -s "$d/.env" "$slot1/.env" || fail "slot $n does not share slot 1's .env"
  for private in .credentials .credentials_rsaparams .service _work _diag runsvc.sh; do
    [ ! -e "$d/$private" ] || fail "slot $n copied slot 1's $private"
  done
  grep -q 'slot1-svc' "$d/svc.sh" && fail "slot $n runs slot 1's svc.sh"
  grep -q "^config $d --unattended --url https://github.com/autumngarage --token regtok --name ci-studio-$n --labels ci-studio-pool --runnergroup Default --work _work --replace$" "$calls" \
    || fail "slot $n was not registered as ci-studio-$n with only the pool label: $(cat "$calls")"
  grep -q "^svc $d install$" "$calls" || fail "slot $n's LaunchAgent was not installed"
  grep -q "^svc $d start$" "$calls" || fail "slot $n's LaunchAgent was not started"
done
grep -q '^as ci$' "$calls" || fail "the runner tools did not run as the account"
! grep -q "^config $slot1 " "$calls" || fail "slot 1 was re-registered"
grep -q 'slots 1..3 present for ci (2 added)' <<<"$out" || fail "the summary did not count the added slots: $out"
grep -q "labels\\[\\]=ci-studio-pool" <<<"$out" || fail "install did not print slot 1's pool-label command"
ok "slots 2 and 3 registered with the pool label, their own svc.sh, and no copied identity"

echo "==> install is idempotent"
: >"$calls"
out="$(run bash "$script" install ci 3)"
! grep -q '^config' "$calls" || fail "a second install re-registered a slot"
grep -q 'slots 1..3 present for ci (0 added)' <<<"$out" || fail "a second install reported additions: $out"
ok "existing slots are left alone, and no token is needed for them"

echo "==> a failed registration is reported"
out="$(run env MACOS_RUNNER_TOKEN=regtok FAKE_CONFIG_FAILS=1 bash "$script" install ci 4 2>&1)" \
  && fail "a failed registration reported success"
grep -q 'could not register slot 4' <<<"$out" || fail "the failure did not name the slot: $out"
ok "a failed registration names the slot"

echo "==> uninstall-slot deregisters and removes one added slot"
: >"$calls"
run bash "$script" uninstall-slot ci 3 >/dev/null 2>&1 && fail "removed a slot without a removal token"
out="$(run env MACOS_RUNNER_REMOVE_TOKEN=rmtok bash "$script" uninstall-slot ci 3)"
[ ! -e "$home/ci/actions-runner-3" ] || fail "slot 3's files remain"
grep -q "^config $home/ci/actions-runner-3 remove --token rmtok$" "$calls" || fail "slot 3 was not deregistered: $(cat "$calls")"
[ -f "$home/ci/actions-runner-2/.runner" ] || fail "removing slot 3 touched slot 2"
ok "slot 3 stopped, deregistered, and removed; slot 2 untouched"

echo "==> PASS: macOS runner slots are added, kept, and removed safely"
