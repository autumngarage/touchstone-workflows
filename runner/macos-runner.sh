#!/usr/bin/env bash
#
# runner/macos-runner.sh -- keep a pool of self-hosted macOS runner slots in
# one CI account on one Mac (AUT-2013).
#
# Usage:
#   sudo MACOS_RUNNER_TOKEN=<registration token> \
#     bash runner/macos-runner.sh install USER SLOTS
#                         keep slots 1..SLOTS for USER; adds only missing ones
#   sudo MACOS_RUNNER_REMOVE_TOKEN=<removal token> \
#     bash runner/macos-runner.sh uninstall-slot USER SLOT
#                         stop, deregister, and remove one added slot (2..)
#
# A slot is one persistent actions runner in USER's home with its own
# directory and its own LaunchAgent in USER's login session, so slots take
# jobs side by side. Every slot carries the pool label
# (MACOS_RUNNER_POOL_LABEL); a job that selects it takes whichever slot is
# free, and adding a slot adds capacity. Slot 1 is the account's existing
# runner, registered by hand as MACOS_RUNNER_NAME: this script never
# re-registers it, and it keeps its own name label, which is how exclusive
# work stays on it -- work that must never overlap itself in one account
# (hesperus's account-wide cleanup) or that holds macOS grants (the smoke).
# Give slot 1 the pool label once with the command `install` prints.
#
# Slots share the account, its login session, and the Mac. Only work that is
# safe side by side in one account may select the pool; everything else
# selects slot 1's name. Each slot is a persistent runner, the same trust
# model as slot 1: the account holds no credential beyond each runner's own
# registration, and fork pull requests never reach these runners (the
# consumer's workflow guards that).
#
# Registration reuses the runner's own tools: `config.sh` registers a slot
# and `svc.sh` installs and starts its LaunchAgent, run as USER inside
# USER's login session (the account must be logged in, as slot 1's already
# is). A slot's runner files are copied from slot 1, so every slot runs the
# same runner version with the same `.path` and `.env`.
#
# Root is used only to become USER. USER's home is writable by USER's jobs,
# so every file operation in it -- creating, copying, removing a slot -- runs
# as USER and can reach nothing USER cannot already reach; a slot path that
# is a symlink is refused.
#
# Configuration, from the environment (defaults in parentheses):
#   MACOS_RUNNER_ORG         organization (autumngarage)
#   MACOS_RUNNER_NAME        slot 1's runner name; slot N is NAME-N (ci-studio)
#   MACOS_RUNNER_POOL_LABEL  the label every slot carries (ci-studio-pool)
#   MACOS_RUNNER_GROUP       runner group for added slots (Default)
#   MACOS_RUNNER_TOKEN       registration token, required only to add a slot:
#                            gh api -X POST orgs/<org>/actions/runners/registration-token --jq .token
#   MACOS_RUNNER_REMOVE_TOKEN  removal token, for uninstall-slot:
#                            gh api -X POST orgs/<org>/actions/runners/remove-token --jq .token
#   MACOS_RUNNER_HOME_ROOT   where home directories live (/Users)
set -euo pipefail

ORG="${MACOS_RUNNER_ORG:-autumngarage}"
NAME="${MACOS_RUNNER_NAME:-ci-studio}"
POOL="${MACOS_RUNNER_POOL_LABEL:-ci-studio-pool}"
GROUP="${MACOS_RUNNER_GROUP:-Default}"
HOME_ROOT="${MACOS_RUNNER_HOME_ROOT:-/Users}"

die() {
  echo "macos-runner: $*" >&2
  exit 1
}
usage() {
  sed -n '6,13p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# Run a command as USER inside USER's login session, so svc.sh's launchctl
# reaches USER's GUI domain rather than root's. MACOS_RUNNER_AS overrides the
# wrapper for tests.
as_user() {
  local user="$1"
  shift
  if [ -n "${MACOS_RUNNER_AS:-}" ]; then
    "$MACOS_RUNNER_AS" "$user" "$@"
  else
    launchctl asuser "$(id -u "$user")" sudo -u "$user" -H "$@"
  fi
}

slot_dir() { # user slot
  if [ "$2" -eq 1 ]; then
    printf '%s/%s/actions-runner' "$HOME_ROOT" "$1"
  else
    printf '%s/%s/actions-runner-%s' "$HOME_ROOT" "$1" "$2"
  fi
}
slot_name() { # slot
  if [ "$1" -eq 1 ]; then printf '%s' "$NAME"; else printf '%s-%s' "$NAME" "$1"; fi
}

require_root() {
  [ -n "${MACOS_RUNNER_AS:-}" ] || [ "$(id -u)" -eq 0 ] \
    || die "run with sudo: slots live in another account's home and login session"
}
require_user() {
  [ -n "$1" ] || usage
  case "$1" in *[!A-Za-z0-9._-]*) die "invalid user '$1'" ;; esac
  [ -d "$HOME_ROOT/$1" ] || die "no home directory for '$1' under $HOME_ROOT"
}
refuse_symlink() { # path
  [ ! -L "$1" ] || die "$1 is a symlink; a slot is a directory in the account's home"
}
require_count() { # value what minimum
  case "$1" in '' | *[!0-9]*) die "$2 must be a positive integer, not '$1'" ;; esac
  [ "$1" -ge "$3" ] || die "$2 must be at least $3, not $1"
}

cmd_install() {
  local user="${1:-}" slots="${2:-}" source dir name slot added=0
  require_user "$user"
  require_count "$slots" SLOTS 1
  require_root
  source="$(slot_dir "$user" 1)"
  [ -f "$source/.runner" ] \
    || die "slot 1 ($source) is not a configured runner; register the account's runner first"

  slot=2
  while [ "$slot" -le "$slots" ]; do
    dir="$(slot_dir "$user" "$slot")"
    name="$(slot_name "$slot")"
    refuse_symlink "$dir"
    if [ -f "$dir/.runner" ]; then
      echo "slot $slot ($name) already registered at $dir"
      slot=$((slot + 1))
      continue
    fi
    # Checked before anything changes, so a missing token leaves no half slot.
    [ -n "${MACOS_RUNNER_TOKEN:-}" ] \
      || die "slot $slot needs registering: set MACOS_RUNNER_TOKEN (see the header)"
    echo "adding slot $slot ($name) at $dir"
    as_user "$user" mkdir -p "$dir" || die "could not create $dir as $user"
    # The runner's files, not slot 1's identity or state: its registration,
    # credentials, service marker, job workspace, and diagnostics stay behind.
    # svc.sh and runsvc.sh are left out too: config.sh writes the slot's own
    # svc.sh, and `svc.sh install` writes its runsvc.sh.
    as_user "$user" rsync -a \
      --exclude '/.runner' --exclude '/.credentials' --exclude '/.credentials_rsaparams' \
      --exclude '/.service' --exclude '/_work' --exclude '/_diag' \
      --exclude '/svc.sh' --exclude '/runsvc.sh' \
      "$source/" "$dir/" || die "could not copy slot 1's runner files to $dir as $user"
    (cd "$dir" && as_user "$user" ./config.sh --unattended \
      --url "https://github.com/$ORG" --token "$MACOS_RUNNER_TOKEN" \
      --name "$name" --labels "$POOL" --runnergroup "$GROUP" \
      --work _work --replace) || die "config.sh could not register slot $slot ($name)"
    (cd "$dir" && as_user "$user" ./svc.sh install && as_user "$user" ./svc.sh start) \
      || die "slot $slot ($name) is registered but its LaunchAgent did not start; see $dir/_diag"
    added=$((added + 1))
    slot=$((slot + 1))
  done

  echo "slots 1..$slots present for $user ($added added)"
  echo "slot 1 needs the pool label once (an org admin, not root):"
  echo "  gh api -X POST orgs/$ORG/actions/runners/\$(gh api orgs/$ORG/actions/runners --paginate --jq '.runners[] | select(.name == \"$NAME\") | .id')/labels -f 'labels[]=$POOL'"
}

cmd_uninstall_slot() {
  local user="${1:-}" slot="${2:-}" dir
  require_user "$user"
  require_count "$slot" SLOT 2
  require_root
  dir="$(slot_dir "$user" "$slot")"
  refuse_symlink "$dir"
  [ -f "$dir/.runner" ] || die "slot $slot is not a configured runner at $dir"
  [ -n "${MACOS_RUNNER_REMOVE_TOKEN:-}" ] || die "set MACOS_RUNNER_REMOVE_TOKEN (see the header)"
  (cd "$dir" && as_user "$user" ./svc.sh stop; as_user "$user" ./svc.sh uninstall) || true
  (cd "$dir" && as_user "$user" ./config.sh remove --token "$MACOS_RUNNER_REMOVE_TOKEN") \
    || die "config.sh could not deregister slot $slot; its files are left at $dir"
  as_user "$user" rm -rf "$dir" || die "slot $slot is deregistered but $dir could not be removed as $user"
  echo "slot $slot ($(slot_name "$slot")) removed"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  uninstall-slot) shift; cmd_uninstall_slot "$@" ;;
  *) usage ;;
esac
