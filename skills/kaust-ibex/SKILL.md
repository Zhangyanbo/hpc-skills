---
name: kaust-ibex
description: >
  Operate the KAUST Ibex HPC cluster (SLURM) over SSH on the user's behalf:
  deploy code, submit / monitor / cancel jobs, manage GPU allocations
  (A100/V100), fetch results back, check quotas / partitions / GPU
  availability, and use the cluster as part of an iterate-loop. Use this skill
  whenever the user mentions running anything on Ibex / the HPC / cluster
  ("run this on ibex", "submit to slurm", "check my ibex jobs", "在 ibex 上跑"),
  asks about job status, storage quota, transferring files to/from the
  cluster, installing packages on the cluster, or anything involving sbatch /
  squeue / srun / sinfo / Ibex — even casually.
---

# KAUST Ibex HPC Operations

Deploy, submit, monitor, and retrieve results on Ibex (SLURM) over SSH, on the
user's behalf. **Top priority: never do anything that could violate cluster
policy or draw administrator attention** (see "Compliance red lines"). When in
doubt, take the slower, by-the-book path — the user's account is not worth any
shortcut.

## 0. Preflight — run this before any Ibex work

All connection details live on the local machine in `~/.config/kaust-ibex/config`
(shell syntax, `KEY=value`). **This skill contains no account information**; the
config file is the single source of truth. Start every Ibex session with:

```bash
bash <this-skill-dir>/scripts/preflight.sh
```

Branch on its output:

- `READY host=... node=...` — connection works; proceed. `source` the config file
  to get:
  - `IBEX_HOST` — ssh target (an alias or `user@host`). Use it everywhere:
    `ssh "$IBEX_HOST" ...`, `rsync ... "$IBEX_HOST":...`
  - `IBEX_USER` — the user's KAUST login
  - `IBEX_PROJECT_ROOT` — durable project storage root, e.g.
    `/ibex/user/<username>` (a project's own remote path, if recorded in that
    project's CLAUDE.md, takes precedence)
- `NO_CONFIG` — first use on this machine; run "Guided setup" below.
- `NO_PASSWORDLESS` — key-based login is broken, or the KAUST network route is
  unreachable (Ibex login nodes are typically only reachable on the KAUST
  network or via VPN). **Stop all automated Ibex operations.** Tell the user:
  passwordless SSH is a prerequisite for automation — set up a key
  (`ssh-keygen` + `ssh-copy-id <host>`), confirm the KAUST VPN/network route is
  active, then retry. Never type passwords for the user or try to work around
  authentication.

### Guided setup (only on NO_CONFIG)

1. Scan for candidates: `grep -B1 -A4 -i 'ibex.kaust.edu.sa' ~/.ssh/config`.
2. If nothing is found or multiple candidates exist, ask the user which Host to
   use and what their KAUST login is. **Never guess account information.**
3. Test passwordless login:
   `ssh -o BatchMode=yes -o ConnectTimeout=10 <host> 'echo OK && hostname'`.
4. On success, write `~/.config/kaust-ibex/config` (template in the header of
   `scripts/preflight.sh`) and `chmod 600` it. Also probe for the durable
   project root: `ssh <host> 'ls -d /ibex/user/$USER 2>/dev/null'` and record
   it in `IBEX_PROJECT_ROOT` if present.
5. On failure, follow NO_PASSWORDLESS above; do not write
   `IBEX_PASSWORDLESS=yes`.

## 1. Compliance red lines (each one is a hard constraint)

1. **Login/frontend nodes are for light operations only**: ls / cat / squeue /
   sbatch / editing small files / small scp. Anything that burns CPU, memory,
   or heavy IO — installing packages, building conda/mamba environments,
   extracting large archives, bulk-deleting big directories, data processing,
   running any program — **must go through a compute node**, either an
   interactive allocation (`salloc`/`srun --pty`) or a batch job (`sbatch`).
2. **Every Ibex action must trace back to an explicit user request.** Once the
   user says "run X on Ibex", the deploy → submit → monitor → retrieve chain
   for that task can run autonomously; actions outside that scope (touching
   other directories, cancelling unrelated jobs) are off-limits.
3. **Destructive operations require a confirmed list first**: bulk `rm`,
   overwriting existing remote results, `scancel` on jobs not submitted in
   this task, killing a persistent interactive/dev-server allocation another
   task may still need.
4. **Rate-limit polling**: status-check loops at ≥ 60-second intervals (don't
   hammer `squeue`). Batch several remote commands into one ssh call
   (`ssh host 'cmd1; cmd2; cmd3'`) — fewer connections, lower latency.
5. **Stay well below quota ceilings.** Check current storage usage
   (`df -h /ibex/user` or the cluster's quota command) before large writes —
   `/ibex/user` can run close to full, and a full filesystem blocks writes for
   every user sharing it, not just the current job.
6. **No restricted data on the cluster.** Never store or enter passwords/API
   keys on the user's behalf — those belong in a project `.env`. Treat any
   logs from persistent dev-server-style jobs (e.g. remote IDE servers) as
   potentially sensitive if they can embed a generated access token/password.

## 2. Status checks (when the user asks "how are my jobs doing?")

Grab everything in one ssh call:

```bash
ssh "$IBEX_HOST" 'squeue --me; echo ---; sacct -X --starttime today -o JobID,JobName%20,State,Elapsed,ExitCode | tail -30'
```

| To see | Command (inside ssh) |
|---|---|
| Running / queued jobs | `squeue --me` |
| Recent job outcomes (incl. failures) | `sacct -X --starttime <date> -o JobID,JobName%20,State,Elapsed,ExitCode` |
| Resource efficiency of a finished job | `seff <jobid>` |
| Storage usage | `df -h /ibex/user` (or the cluster's official quota command) |
| Partition / node states | `sinfo` |
| GPU availability | `sinfo -o "%n %G %f %t"` (single `batch` partition; filter by feature/GRES) |
| Job logs | `tail -50 <submit-dir>/slurm-<jobid>.out` (or the path set via `--output`) |
| Recover a job's real account/QOS/paths | `scontrol show job <id>` |

Failure triage order: tail of the `.err` file → `sacct` State/ExitCode (`OOM` →
more memory, `TIMEOUT` → more time, `NODE_FAIL`/`PREEMPTED` → just resubmit) →
`seff` to see whether resources were undersized.

## 3. Task routing

- **Deploying code / transferring files / setting up environments (conda, uv) /
  storage & quota issues** → read [references/deploy.md](references/deploy.md) first.
- **Writing SLURM scripts / submitting jobs / GPU-type-aware requests / debugging
  jobs / interactive & persistent-dev-server sessions** → read
  [references/slurm.md](references/slurm.md) first.
- Both at once (the common "run X on Ibex") → read both, execute in
  deploy → slurm order.

## 4. Using Ibex inside a loop (submit → wait → retrieve → iterate)

Standard loop skeleton:

1. Deploy changed files (full dependency-chain check, see deploy.md), then
   submit (see slurm.md).
2. Wait in the background, polling at ≥ 60s intervals (scale up to 5–10
   minutes for long jobs):
   ```bash
   ssh "$IBEX_HOST" 'squeue --me -h | wc -l'   # 0 = everything finished
   ```
   When the queue drains, immediately classify with `sacct` — COMPLETED vs
   FAILED vs PREEMPTED/TIMEOUT. An empty queue does not mean success.
3. Retrieve results: `rsync -azP "$IBEX_HOST":<remote>/results/ ./results/`
   (incremental; safe to re-run).
4. Analyze locally → adjust code/parameters → back to 1. Re-run only the
   missing tasks using the idempotent submit pattern (slurm.md, "Idempotent
   submit pattern") — that pattern is what makes the whole loop safely
   re-entrant.

## 5. Key cluster facts (quick recall; details in references/)

- Scheduler: SLURM, reached over SSH from a login/frontend node.
- Ibex uses a **single default `batch` partition** for CPU and GPU jobs alike;
  you pick hardware via `--gpus`/`--gres` plus `--constraint=<gpu-type>`
  (`a100`, `v100`, `rtx2080ti`, `gtx1080ti`, …), not via a GPU partition.
  Wall-time cap is uniform (14 days). Constraint names and limits can drift —
  verify live with `sinfo -o "%P %l %D %c %m %G"` and
  `sinfo -o "%n %G %f %t"`.
- Two login nodes: `ilogin` (CPU) and `glogin` (GPU — use it when a build
  needs to see a GPU, e.g. compiling CUDA code).
- Durable project storage lives under `/ibex/user/<username>` (1.5 TB per
  user, persists for the account's lifetime), distinct from the login home
  directory (200 GB **and a file-count quota** — another reason conda envs
  belong under `/ibex/user`) — do not conflate the two in scripts or project
  memory.
- Off-campus access to Ibex typically requires the KAUST network or VPN;
  if a connection that worked on campus fails off campus, that's the first
  thing to check, not SSH key configuration.
- Ibex is only reachable this way if the user's local SSH client is correctly
  routed (VPN / network) — that routing is local machine configuration, not
  something this skill manages.

## 6. Off-campus / VPN access (knowledge, not an operation)

This section is background to *explain* when the user asks about connection
problems — it is not something this skill configures or performs on its own.
The skill always just uses `$IBEX_HOST`; whether that route needs KAUST's VPN
or a specific network is the user's local SSH client configuration, entirely
outside the skill's operational scope. Check current KAUST IT documentation
for the up-to-date VPN/SSH requirements, since these evolve independently of
this skill.
