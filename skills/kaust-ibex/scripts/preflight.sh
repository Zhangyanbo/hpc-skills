#!/usr/bin/env bash
# Preflight for the kaust-ibex skill: verify local config + passwordless SSH.
#
# Config file: ~/.config/kaust-ibex/config  (shell syntax; chmod 600)
# Template:
#   # KAUST Ibex connection config — used by the kaust-ibex skill. Keep private.
#   IBEX_HOST=<ssh alias from ~/.ssh/config, or user@<ibex-login-host>>
#   IBEX_USER=<your KAUST login>
#   IBEX_PASSWORDLESS=yes            # set by this script after a successful test
#   IBEX_PASSWORDLESS_CHECKED=<date>
#   IBEX_PROJECT_ROOT=               # /ibex/user/<username> if you have one
#
# Exit codes: 0 READY | 2 NO_CONFIG or BAD_CONFIG | 3 NO_PASSWORDLESS
set -u

CONFIG="${KAUST_IBEX_CONFIG:-$HOME/.config/kaust-ibex/config}"

if [[ ! -f "$CONFIG" ]]; then
  echo "NO_CONFIG: $CONFIG not found — run the guided setup in SKILL.md"
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG"

if [[ -z "${IBEX_HOST:-}" ]]; then
  echo "BAD_CONFIG: IBEX_HOST is not set in $CONFIG"
  exit 2
fi

out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$IBEX_HOST" 'echo __OK__ && hostname' 2>&1)
if grep -q '__OK__' <<<"$out"; then
  node=$(printf '%s\n' "$out" | tail -1)
  echo "READY host=$IBEX_HOST node=$node"
  exit 0
fi

echo "NO_PASSWORDLESS: BatchMode ssh to '$IBEX_HOST' failed — check KAUST VPN/network route or key-based login"
printf '%s\n' "$out" | tail -3
exit 3
