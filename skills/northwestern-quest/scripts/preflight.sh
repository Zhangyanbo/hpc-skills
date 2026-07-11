#!/usr/bin/env bash
# Preflight for the northwestern-quest skill: verify local config + passwordless SSH.
#
# Config file: ~/.config/quest-hpc/config  (shell syntax; chmod 600)
# Template:
#   # Northwestern Quest connection config — used by the northwestern-quest skill. Keep private.
#   QUEST_HOST=<ssh alias from ~/.ssh/config, or user@login.quest.northwestern.edu>
#   QUEST_NETID=<your Northwestern NetID>
#   QUEST_PASSWORDLESS=yes            # set by this script after a successful test
#   QUEST_PASSWORDLESS_CHECKED=<date>
#   QUEST_ALLOCATION_ROOT=            # /projects/<allocationID> (or a subdir) if you have one
#   QUEST_SCRATCH_ROOT=               # /scratch/<netid> (auto-purged; optional)
#
# Exit codes: 0 READY | 2 NO_CONFIG or BAD_CONFIG | 3 NO_PASSWORDLESS
set -u

CONFIG="${QUEST_HPC_CONFIG:-$HOME/.config/quest-hpc/config}"

if [[ ! -f "$CONFIG" ]]; then
  echo "NO_CONFIG: $CONFIG not found — run the guided setup in SKILL.md"
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG"

if [[ -z "${QUEST_HOST:-}" ]]; then
  echo "BAD_CONFIG: QUEST_HOST is not set in $CONFIG"
  exit 2
fi

out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$QUEST_HOST" 'echo __OK__ && hostname' 2>&1)
if grep -q '__OK__' <<<"$out"; then
  node=$(printf '%s\n' "$out" | tail -1)
  echo "READY host=$QUEST_HOST node=$node"
  exit 0
fi

echo "NO_PASSWORDLESS: BatchMode ssh to '$QUEST_HOST' failed — key-based login required for automation"
printf '%s\n' "$out" | tail -3
exit 3
