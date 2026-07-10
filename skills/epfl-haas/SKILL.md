---
name: epfl-haas
description: >
  Operate an EPFL RunAI/Kubernetes GPU cluster ("Haas"-style setups) over SSH
  on the user's behalf: deploy code, submit / monitor / cancel RunAI jobs,
  manage PVC-backed persistent storage, fetch results back, check node-pool /
  GPU availability, and use the cluster as part of an iterate-loop. Unlike a
  SLURM cluster, jobs here are Kubernetes pods scheduled by RunAI — there is
  no sbatch/squeue. Use this skill whenever the user mentions running
  something on an EPFL RunAI cluster, PVC-backed pods, "haas", RunAI jobs, or
  anything involving `runai submit` / `runai list` / `runai describe` — even
  casually.
---

# EPFL RunAI ("Haas") GPU Cluster Operations

Deploy, submit, monitor, and retrieve results on an EPFL RunAI/Kubernetes GPU
cluster over SSH, on the user's behalf. **Top priority: never do anything
that could violate cluster policy or draw administrator attention** (see
"Compliance red lines"). When in doubt, take the slower, by-the-book path —
the user's account is not worth any shortcut.

This is a **RunAI/Kubernetes** environment, not SLURM: there is no
`sbatch`/`squeue`/`sinfo`. Jobs are Kubernetes pods submitted and inspected
via the `runai` CLI, scheduled across GPU **node pools** rather than SLURM
partitions.

## 0. Preflight — run this before any Haas work

All connection details live on the local machine in
`~/.config/epfl-haas/config` (shell syntax, `KEY=value`). **This skill
contains no account information**; the config file is the single source of
truth. Start every Haas session with:

```bash
bash <this-skill-dir>/scripts/preflight.sh
```

Branch on its output:

- `READY host=... node=...` — SSH to the control-plane host works; proceed.
  `source` the config file to get:
  - `HAAS_HOST` — ssh target (an alias or `user@host`) for the control-plane
    host used to run `runai` commands. Use it everywhere:
    `ssh "$HAAS_HOST" ...`
  - `HAAS_USER` — the user's login
  - `HAAS_PVC_ROOT` — durable PVC-backed project storage root (a project's
    own remote path, if recorded in that project's CLAUDE.md, takes
    precedence)
  - Note: a `READY` preflight only confirms SSH — it does **not** confirm
    `runai` auth. RunAI's own login/OAuth token can expire independently;
    see §2.
- `NO_CONFIG` — first use on this machine; run "Guided setup" below.
- `NO_PASSWORDLESS` — key-based login is broken, or the network route (VPN)
  to the control-plane host is unreachable. **Stop all automated Haas
  operations.** Tell the user: passwordless SSH is a prerequisite for
  automation — set up a key, confirm VPN/network routing, then retry. Never
  type passwords for the user or try to work around authentication.

### Guided setup (only on NO_CONFIG)

1. Ask the user for their control-plane SSH alias/host and RunAI project
   name — **never guess account information**.
2. Test passwordless login:
   `ssh -o BatchMode=yes -o ConnectTimeout=10 <host> 'echo OK && hostname'`.
3. On success, write `~/.config/epfl-haas/config` (template in the header of
   `scripts/preflight.sh`) and `chmod 600` it.
4. On failure, follow NO_PASSWORDLESS above; do not write
   `HAAS_PASSWORDLESS=yes`.

## 1. Compliance red lines (each one is a hard constraint)

1. **The control-plane host is for light operations only**: ls / cat /
   `runai list` / editing small files / short scp. Anything that burns CPU,
   memory, or heavy IO — dependency installs, extracting large archives, bulk
   deletes, data processing, running any program — **must go through a RunAI
   pod**, not the control-plane shell.
2. **Every Haas action must trace back to an explicit user request.** Once
   the user says "run X on Haas", the deploy → submit → monitor → retrieve
   chain for that task can run autonomously; actions outside that scope
   (touching other projects' namespaces, deleting unrelated jobs) are
   off-limits.
3. **Destructive operations require a confirmed list first**: bulk `rm` on
   PVC storage, overwriting existing checkpoints/outputs, deleting jobs not
   submitted in this task, releasing a shared/opportunistic allocation
   another task may still need.
4. **Rate-limit polling**: status-check loops at ≥ 60-second intervals; batch
   `runai describe`/`runai list` calls in one ssh round-trip where possible
   instead of many separate calls.
5. **Stay well below storage ceilings.** PVC usage can grow quietly, e.g.
   from per-run virtualenv/cache proliferation — before large writes or many
   new environments, sanity-check actual physical usage (`du`, `stat` for
   hard-link sharing) rather than assuming each new env is fully additional.
6. **No restricted data on the cluster.** Never store or enter passwords/API
   keys on the user's behalf — those belong in a project `.env` or mounted
   secret, not inline in `runai submit -e ...` flags when avoidable. Treat
   `runai describe job` output as potentially sensitive: it can echo the
   original submit command and environment variables — don't paste it raw
   into chats, docs, or commits.

## 2. RunAI auth is separate from SSH

A working `READY` preflight only proves SSH to the control-plane host works.
`runai` itself typically needs its own login flow (often OAuth-based), and
that token can expire independently of the SSH session. Before trusting a
`runai` command's output:

```bash
ssh "$HAAS_HOST" 'runai whoami'
```

If this fails with an auth/token error (e.g. `invalid_grant` or similar),
the fix is a `runai login` (or the cluster's current equivalent) — report
the exact re-login step to the user rather than continuing with what would
be misleading job-status analysis on a stale/failed auth session.

## 3. Status checks (when the user asks "how are my jobs doing?")

```bash
ssh "$HAAS_HOST" 'runai list jobs; echo ---; runai whoami'
```

| To see | Command (inside ssh) |
|---|---|
| Jobs and their status | `runai list jobs` |
| One job's detail (submit command, node, events) | `runai describe job <name>` |
| Live logs | `runai logs <name>` |
| Node-pool / GPU availability | `runai list nodepools` (or the cluster's equivalent inspection command) |
| Current login/auth state | `runai whoami` |
| Cancel/delete a job | `runai delete job <name>` |

Failure triage order: `runai describe job <name>` events (distinguish
node-pool saturation from project fair-share/quota, or a plain code error) →
`runai logs <name>` tail → re-check `runai whoami` if the describe/logs
output looks stale or the job never left `Pending`. Treat `ContainerCreating`,
long image pulls, and image-cache misses as node/image startup problems, not
code failures.

## 4. Task routing

- **Deploying code / transferring files / setting up environments (conda, uv)
  / PVC storage layout** → read [references/deploy.md](references/deploy.md)
  first.
- **Submitting RunAI jobs / choosing node pools / interactive vs batch pods /
  debugging jobs** → read [references/runai.md](references/runai.md) first.
- Both at once (the common "run X on Haas") → read both, execute in
  deploy → runai order.

## 5. Using Haas inside a loop (submit → wait → retrieve → iterate)

Standard loop skeleton:

1. Deploy changed files (full dependency-chain check, see deploy.md), then
   submit (see runai.md).
2. Wait in the background, polling at ≥ 60s intervals:
   ```bash
   ssh "$HAAS_HOST" 'runai list jobs | grep -c Running'
   ```
   Then immediately classify with `runai list jobs` / `runai describe job` —
   Succeeded vs Failed vs still-Pending. An empty "Running" count does not by
   itself mean success.
3. Retrieve results: `rsync -azP "$HAAS_HOST":<PVC-path>/results/ ./results/`
   (incremental; safe to re-run) — assumes SSH access to a path that mounts
   the same PVC, e.g. the control-plane host or an interactive pod's exposed
   path.
4. Analyze locally → adjust code/parameters → back to 1. Re-run only the
   missing tasks using the idempotent submit pattern (runai.md, "Idempotent
   job-matrix submission") — that pattern is what makes the whole loop safely
   re-entrant.

## 6. Key cluster facts (quick recall; details in references/)

- Scheduler: RunAI on Kubernetes, reached via the `runai` CLI from a
  control-plane host — no `sbatch`/`squeue`/`sinfo` equivalents.
- Persistent storage is PVC-backed; the pod/container root filesystem does
  **not** survive pod restarts — anything that must persist (code, venvs,
  data, checkpoints) belongs on the PVC-backed path.
- Node pools stand in for SLURM partitions, but "default" does not
  necessarily mean "any available GPU" — it can effectively pin to one GPU
  class. Node-pool names, GPU classes, and quota (deserved vs opportunistic)
  are cluster/project-specific; verify live rather than assuming a fixed
  mapping from another project.
- `runai` auth (login/OAuth token) is separate from SSH auth to the
  control-plane host and can expire independently — see §2.

## 7. Off-campus / VPN access (knowledge, not an operation)

This section is background to *explain* when the user asks about connection
problems — it is not something this skill configures or performs on its own.
The skill always just uses `$HAAS_HOST`; whether that route needs a VPN is
the user's local SSH client configuration, entirely outside the skill's
operational scope. Check current institutional IT documentation for the
up-to-date VPN/SSH requirements, since these evolve independently of this
skill.
