#!/usr/bin/env bash
# Existing Runscaler service, with its JSON lifecycle stream as wake-up hints.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_TOKEN="$(cat "$CREDENTIALS_DIRECTORY/github-token")"
export RUNNER_TOKEN
GH_TOKEN="$RUNNER_TOKEN"
export GH_TOKEN
exec python3 -I "$here/kvm-admission.py" listen
