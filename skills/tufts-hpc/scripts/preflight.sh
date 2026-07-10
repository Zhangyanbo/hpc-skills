#!/usr/bin/env bash
# Preflight for the tufts-hpc skill: verify local config + passwordless SSH.
#
# Config file: ~/.config/tufts-hpc/config  (shell syntax; chmod 600)
# Template:
#   # Tufts HPC connection config — used by the tufts-hpc skill. Keep private.
#   HPC_HOST=<ssh alias from ~/.ssh/config, or user@login-prod.pax.tufts.edu>
#   HPC_USER=<your UTLN>
#   HPC_PASSWORDLESS=yes            # set by this script after a successful test
#   HPC_PASSWORDLESS_CHECKED=<date>
#   HPC_DEFAULT_REMOTE_ROOT=~/research   # default deployment root on the cluster
#   HPC_RESEARCH_DIR=               # /cluster/tufts/<lab>/<utln> if you have one
#
# Exit codes: 0 READY | 2 NO_CONFIG or BAD_CONFIG | 3 NO_PASSWORDLESS
set -u

CONFIG="${TUFTS_HPC_CONFIG:-$HOME/.config/tufts-hpc/config}"

if [[ ! -f "$CONFIG" ]]; then
  echo "NO_CONFIG: $CONFIG not found — run the guided setup in SKILL.md"
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG"

if [[ -z "${HPC_HOST:-}" ]]; then
  echo "BAD_CONFIG: HPC_HOST is not set in $CONFIG"
  exit 2
fi

out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HPC_HOST" 'echo __OK__ && hostname' 2>&1)
if grep -q '__OK__' <<<"$out"; then
  node=$(printf '%s\n' "$out" | tail -1)
  echo "READY host=$HPC_HOST node=$node"
  exit 0
fi

echo "NO_PASSWORDLESS: BatchMode ssh to '$HPC_HOST' failed — key-based login required for automation"
printf '%s\n' "$out" | tail -3
exit 3
