#!/usr/bin/env bash
# Preflight for the epfl-haas skill: verify local config + passwordless SSH to
# the control-plane host. Note: this only checks SSH, not `runai` auth — see
# SKILL.md §2 for the separate `runai whoami` check.
#
# Config file: ~/.config/epfl-haas/config  (shell syntax; chmod 600)
# Template:
#   # EPFL RunAI/Haas connection config — used by the epfl-haas skill. Keep private.
#   HAAS_HOST=<ssh alias from ~/.ssh/config, or user@<control-plane-host>>
#   HAAS_USER=<your login>
#   HAAS_PASSWORDLESS=yes            # set by this script after a successful test
#   HAAS_PASSWORDLESS_CHECKED=<date>
#   HAAS_PROJECT=                    # RunAI project name (runai config project <name>)
#   HAAS_PVC_ROOT=                   # PVC-backed project root, if known
#
# Exit codes: 0 READY | 2 NO_CONFIG or BAD_CONFIG | 3 NO_PASSWORDLESS
set -u

CONFIG="${EPFL_HAAS_CONFIG:-$HOME/.config/epfl-haas/config}"

if [[ ! -f "$CONFIG" ]]; then
  echo "NO_CONFIG: $CONFIG not found — run the guided setup in SKILL.md"
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG"

if [[ -z "${HAAS_HOST:-}" ]]; then
  echo "BAD_CONFIG: HAAS_HOST is not set in $CONFIG"
  exit 2
fi

out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HAAS_HOST" 'echo __OK__ && hostname' 2>&1)
if grep -q '__OK__' <<<"$out"; then
  node=$(printf '%s\n' "$out" | tail -1)
  echo "READY host=$HAAS_HOST node=$node"
  exit 0
fi

echo "NO_PASSWORDLESS: BatchMode ssh to '$HAAS_HOST' failed — check VPN/network route or key-based login"
printf '%s\n' "$out" | tail -3
exit 3
