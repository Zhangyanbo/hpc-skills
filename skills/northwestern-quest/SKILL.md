---
name: northwestern-quest
description: >
  Operate the Northwestern University Quest HPC cluster (SLURM) over SSH on the
  user's behalf: deploy code, submit / monitor / cancel jobs, manage GPU
  allocations, fetch results back, check quotas / partitions / GPU availability,
  and use the cluster as part of an iterate-loop. Use this skill whenever the
  user mentions running anything on Quest / the HPC / cluster ("run this on
  Quest", "submit to slurm", "check my quest jobs", "在 quest 上跑"), asks
  about job status, storage quota, transferring files to/from the cluster,
  installing packages on the cluster, or anything involving sbatch / squeue /
  srun / sinfo / Quest — even casually.
---

# Northwestern Quest HPC Operations

Deploy, submit, monitor, and retrieve results on Quest (SLURM) over SSH, on the
user's behalf. **Top priority: never do anything that could violate cluster
policy or draw administrator attention** (see "Compliance red lines"). When in
doubt, take the slower, by-the-book path — the user's account is not worth any
shortcut.

## 0. Preflight — run this before any Quest work

All connection details live on the local machine in `~/.config/quest-hpc/config`
(shell syntax, `KEY=value`). **This skill contains no account information**; the
config file is the single source of truth. Start every Quest session with:

```bash
bash <this-skill-dir>/scripts/preflight.sh
```

Branch on its output:

- `READY host=... node=...` — connection works; proceed. `source` the config file
  to get:
  - `QUEST_HOST` — ssh target (an alias or `user@host`). Use it everywhere:
    `ssh "$QUEST_HOST" ...`, `rsync ... "$QUEST_HOST":...`
  - `QUEST_NETID` — the user's Northwestern NetID
  - `QUEST_ALLOCATION_ROOT` — default project storage root, e.g.
    `/projects/<allocation>/<netid>` (a project's own remote path, if recorded
    in that project's CLAUDE.md, takes precedence)
  - `QUEST_SCRATCH_ROOT` — `/scratch/<netid>` (auto-purged; see storage notes)
- `NO_CONFIG` — first use on this machine; run "Guided setup" below.
- `NO_PASSWORDLESS` — key-based login is broken. **Stop all automated Quest
  operations.** Tell the user: passwordless SSH is a prerequisite for
  automation — set up a key (`ssh-keygen` + `ssh-copy-id <host>`), then retry.
  Never type passwords for the user or try to work around authentication.

### Guided setup (only on NO_CONFIG)

1. Scan for candidates: `grep -B1 -A4 -i 'quest.northwestern.edu' ~/.ssh/config`.
2. If nothing is found or multiple candidates exist, ask the user which Host to
   use and what their NetID is. **Never guess account information.**
3. Test passwordless login:
   `ssh -o BatchMode=yes -o ConnectTimeout=10 <host> 'echo OK && hostname'`.
4. On success, write `~/.config/quest-hpc/config` (template in the header of
   `scripts/preflight.sh`) and `chmod 600` it. Also probe for the project
   allocation root: `ssh <host> 'ls -d /projects/*/$USER 2>/dev/null'` and
   record it in `QUEST_ALLOCATION_ROOT` if present.
5. On failure, follow NO_PASSWORDLESS above; do not write
   `QUEST_PASSWORDLESS=yes`.

## 1. Compliance red lines (each one is a hard constraint)

1. **Login nodes are for light operations only**: ls / cat / squeue / sbatch /
   editing small files / small scp. Anything that burns CPU, memory, or heavy IO
   — installing packages, building conda/mamba environments, extracting large
   archives, bulk-deleting big directories, data processing, running any
   program — **must go through a compute node**, either an interactive
   allocation (`salloc`) or a batch job (`sbatch`).
2. **Every Quest action must trace back to an explicit user request.** Once the
   user says "run X on Quest", the deploy → submit → monitor → retrieve chain
   for that task can run autonomously; actions outside that scope (touching
   other directories, cancelling unrelated jobs) are off-limits.
3. **Destructive operations require a confirmed list first**: bulk `rm`,
   overwriting existing remote results, `scancel` on jobs not submitted in this
   task, killing an interactive/placeholder allocation another task may still
   need.
4. **Rate-limit polling**: status-check loops at ≥ 60-second intervals (don't
   hammer `squeue`). Batch several remote commands into one ssh call
   (`ssh host 'cmd1; cmd2; cmd3'`) — fewer connections, lower latency.
5. **Stay well below quota ceilings.** Before a large submission, check current
   allocation load with `squeue -u <netid> | wc -l`. GPU allocations
   (`QOSMaxGRESPerUser` and similar) are limited per user — too many long-lived
   interactive/placeholder jobs blocks new `sbatch` submissions with that
   pending reason.
6. **No restricted data on the cluster** (HIPAA, FERPA, etc.). Never store or
   enter passwords/API keys (e.g. `WANDB_API_KEY`, `HF_TOKEN`) on the user's
   behalf — those belong in a project `.env`.

## 2. Status checks (when the user asks "how are my jobs doing?")

Grab everything in one ssh call:

```bash
ssh "$QUEST_HOST" 'squeue -u '"$QUEST_NETID"'; echo ---; sacct -X --starttime today -o JobID,JobName%20,State,Elapsed,ExitCode | tail -30'
```

| To see | Command (inside ssh) |
|---|---|
| Running / queued jobs | `squeue -u <netid>` |
| Recent job outcomes (incl. failures) | `sacct -X --starttime <date> -o JobID,JobName%20,State,Elapsed,ExitCode` |
| Resource efficiency of a finished job | `seff <jobid>` |
| Storage quota | check the allocation's quota per Quest's storage documentation; quotas are set per PI allocation, not per user |
| Partition / node states | `sinfo` |
| GPU availability | `sinfo -p gengpu -o "%n %G %t"` (adjust partition name to the allocation's GPU partition) |
| Job logs | `tail -50 <submit-dir>/slurm-<jobid>.out` (or the path set via `--output`) |
| Live GPU utilization on an allocated node | `ssh "$QUEST_HOST" "ssh <node> 'nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader'"` |

Failure triage order: tail of the `.err` file → `sacct` State/ExitCode (`OOM` →
more memory, `TIMEOUT` → more time, `NODE_FAIL`/`PREEMPTED` → just resubmit) →
`seff` to see whether resources were undersized. A `RUNNING` job with 0% GPU
utilization and near-zero memory is very likely an idle interactive placeholder,
not active training — always verify GPU utilization before assuming a job is
doing useful work.

## 3. Task routing

- **Deploying code / transferring files / setting up environments (conda, uv) /
  storage & quota issues** → read [references/deploy.md](references/deploy.md) first.
- **Writing SLURM scripts / submitting jobs / GPU-type-aware requests / debugging
  jobs / long-running detached processes** → read [references/slurm.md](references/slurm.md) first.
- Both at once (the common "run X on Quest") → read both, execute in
  deploy → slurm order.

## 4. Using Quest inside a loop (submit → wait → retrieve → iterate)

Standard loop skeleton:

1. Deploy changed files (full dependency-chain check, see deploy.md), then submit
   (see slurm.md).
2. Wait in the background, polling at ≥ 60s intervals (scale up to 5–10 minutes
   for long jobs):
   ```bash
   ssh "$QUEST_HOST" 'squeue -u '"$QUEST_NETID"' -h | wc -l'   # 0 = everything finished
   ```
   When the queue drains, immediately classify with `sacct` — COMPLETED vs
   FAILED vs PREEMPTED/TIMEOUT. An empty queue does not mean success.
3. Retrieve results: `rsync -azP "$QUEST_HOST":<remote>/results/ ./results/`
   (incremental; safe to re-run).
4. Analyze locally → adjust code/parameters → back to 1. Re-run only the missing
   tasks using the idempotent submit pattern (slurm.md, "Idempotent submit
   pattern") — that pattern is what makes the whole loop safely re-entrant.

## 5. Key cluster facts (quick recall; details in references/)

- Scheduler: SLURM, reached over SSH from a login node.
- GPU partition names and hardware mix vary by allocation (Quest offers pools
  such as `gengpu` with a mix of GPU generations, e.g. A100 and H100). Always
  verify live with `sinfo -o "%P %l %D %c %m %G"` rather than assuming a fixed
  partition name — allocations differ per PI group.
- Durable project storage lives under `/projects/<allocation>/<netid>/`, sized
  per the PI's storage allocation.
- `/scratch/<netid>/` exists for temporary large outputs but is **auto-purged**
  (commonly after ~30 days) — never treat it as durable.
- Conda/mamba environments must be explicitly activated in non-interactive
  shells (SSH / SLURM scripts) — do not rely on `.bashrc` being sourced; source
  the cluster's mamba/conda init script directly.
- `tmux` is not available on Quest compute nodes; use `nohup ... </dev/null
  >log 2>&1 & disown` for long-running detached processes instead.

## 6. Off-campus access (knowledge, not an operation)

This section is background to *explain* when the user asks about connection
problems — it is not something this skill configures or performs on its own.
The skill always just uses `$QUEST_HOST`; whether that route needs a VPN is the
user's local SSH client configuration, entirely outside the skill's operational
scope. If off-campus access requires Northwestern's VPN, the same "install a
key, set `HostName` to the login endpoint" recipe applies — check current
Northwestern IT documentation for the up-to-date VPN/SSH requirements, since
these evolve independently of this skill.
