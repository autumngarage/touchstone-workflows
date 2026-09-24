#!/usr/bin/env bash
#
# runner/jit.sh -- what every runner supervisor here shares, sourced rather
# than run: its GitHub credential, the runner group it registers into, and the
# just-in-time registrations it asks GitHub for. A supervisor sources it from
# its own directory, so an installed copy carries it alongside.
#
# The caller sets ORG, GROUP, LABEL, and TOKEN_FILE before calling these.
#
# Runs under macOS's /bin/bash 3.2: no associative arrays, mapfile, or wait -n.

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH; $2"
}

# A file's permission bits and owner. GNU stat first: on Linux `stat -f` means
# --file-system and succeeds with the wrong answer, while BSD stat refuses -c.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
file_owner() { stat -c %U "$1" 2>/dev/null || stat -f %Su "$1"; }

# gh's credential when it cannot use a login keychain: the token file, which
# must be private to its owner, since whoever reads it can register runners.
load_token() {
  local mode
  [ -z "${GH_TOKEN:-}" ] || return 0
  [ -n "$TOKEN_FILE" ] || return 0
  [ -r "$TOKEN_FILE" ] || die "the token file $TOKEN_FILE is missing or unreadable"
  mode="$(file_mode "$TOKEN_FILE")"
  case "$mode" in
    600 | 400) ;;
    *) die "the token file $TOKEN_FILE is mode $mode; make it private: chmod 600 '$TOKEN_FILE'" ;;
  esac
  GH_TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"
  [ -n "$GH_TOKEN" ] || die "the token file $TOKEN_FILE is empty"
  export GH_TOKEN
}

# The one runner group a supervisor registers into, checked as the host's
# trust boundary: exactly one group of that name, visible only to repositories
# named one by one, closed to public repositories, and holding only private
# ones. A public repository takes fork pull requests; if the group ever
# admitted one, a stranger's code could run here. Prints the group's id, or
# dies.
group_id() {
  local groups count gid repos public
  groups="$(gh api --paginate "orgs/$ORG/actions/runner-groups" \
    --jq ".runner_groups[] | select(.name == \"$GROUP\") | {id, visibility, allows_public_repositories} | tojson")" \
    || die "could not list $ORG's runner groups; check 'gh auth status' for admin:org"
  count="$(printf '%s\n' "$groups" | grep -c '"id"' || true)"
  [ "$count" -eq 1 ] || die "expected one runner group named '$GROUP' in $ORG, found $count; create it as README.md \"Runner\" describes"
  printf '%s' "$groups" | jq -e '.visibility == "selected" and .allows_public_repositories == false' >/dev/null \
    || die "runner group '$GROUP' must be visible only to selected repositories and closed to public ones: $groups"
  gid="$(printf '%s' "$groups" | jq -r '.id')"
  repos="$(gh api --paginate "orgs/$ORG/actions/runner-groups/$gid/repositories" \
    --jq '.repositories[] | "\(.full_name) \(.private)"')" \
    || die "could not list the repositories of runner group '$GROUP'"
  [ -n "$repos" ] || die "runner group '$GROUP' has no repositories; no job could reach these runners"
  public="$(printf '%s\n' "$repos" | awk '$2 != "true" { print $1 }')"
  [ -z "$public" ] || die "runner group '$GROUP' admits a repository that is not private: $public"
  printf '%s\n' "$gid"
}

# request_jit NAME GID: register NAME in runner group GID for exactly one job
# and print GitHub's response, or fail with it. A just-in-time registration
# gets only the labels it is given, not the defaults config.sh adds, and every
# workflow selector requires both.
request_jit() {
  gh api -X POST "orgs/$ORG/actions/runners/generate-jitconfig" \
    -f name="$1" -F runner_group_id="$2" -f "labels[]=self-hosted" -f "labels[]=$LABEL" \
    -f work_folder=_work 2>&1
}

# Best effort: GitHub removes a single-use runner after its job, so a 404 here
# is the normal case. A runner that never took a job would otherwise stay
# registered, offline, until GitHub expires it.
forget_runner() {
  local id="$1"
  [ -n "$id" ] || return 0
  gh api -X DELETE "orgs/$ORG/actions/runners/$id" >/dev/null 2>&1 || true
}
