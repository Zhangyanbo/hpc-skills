---
name: tufts-hpc
description: >
  Operate the Tufts University HPC cluster (SLURM) over SSH on the user's behalf:
  deploy code, submit / monitor / cancel jobs, run array-job experiment matrices,
  fetch results back, check quotas / partitions / GPU availability, and use the
  cluster as part of an iterate-loop. Use this skill whenever the user mentions
  running anything on the HPC / cluster / 集群 / 服务器 ("把它放到 hpc 上跑",
  "run this on the cluster", "submit to slurm", "在集群上训练"), asks about job
  status ("hpc 上跑得怎么样", "check my jobs", "任务跑完了吗"), storage quota,
  transferring files to/from the cluster, installing packages on the cluster, or
  anything involving sbatch / squeue / srun / sinfo / Tufts HPC — even casually.
---

# Tufts HPC Operations

Deploy, submit, monitor, and retrieve results on the Tufts HPC (SLURM) cluster over
SSH, on the user's behalf. **Top priority: never do anything that could violate
cluster policy or draw administrator attention** (see "Compliance red lines").
When in doubt, take the slower, by-the-book path — the user's account is not worth
any shortcut.

## 0. Preflight — run this before any HPC work

All connection details live on the local machine in `~/.config/tufts-hpc/config`
(shell syntax, `KEY=value`). **This skill contains no account information**; the
config file is the single source of truth. Start every HPC session with:

```bash
bash <this-skill-dir>/scripts/preflight.sh
```

(ssh may print warnings such as post-quantum key-exchange notices, possibly twice
when a jump host is in the path — that is normal noise, not an error.)

Branch on its output:

- `READY host=... node=...` — connection works; proceed. `source` the config file
  to get:
  - `HPC_HOST` — ssh target (an alias or `user@host`). Use it everywhere:
    `ssh "$HPC_HOST" ...`, `rsync ... "$HPC_HOST":...`
  - `HPC_USER` — the user's Tufts UTLN
  - `HPC_DEFAULT_REMOTE_ROOT` — default deployment root (a project's own remote
    path, if recorded in that project's CLAUDE.md, takes precedence)
  - `HPC_RESEARCH_DIR` — research-storage path (may be empty = user has no lab
    storage yet; warn before placing large data anywhere)
- `NO_CONFIG` — first use on this machine; run "Guided setup" below.
- `NO_PASSWORDLESS` — key-based login is broken. **Stop all automated HPC
  operations.** Tell the user: passwordless SSH is a prerequisite for automation —
  set up a key (`ssh-keygen` + `ssh-copy-id <host>`; if a jump host is involved,
  it needs a key too), then retry. Never type passwords for the user or try to
  work around authentication.

### Guided setup (only on NO_CONFIG)

1. Scan for candidates: `grep -B1 -A4 -i 'pax.tufts.edu' ~/.ssh/config`.
   Prefer an alias whose HostName is `login-prod.pax.tufts.edu` (the new cluster).
   `login.pax.tufts.edu` (no `-prod`) is the old cluster being retired — do not use it.
2. If nothing is found or multiple candidates exist, ask the user which Host to
   use and what their UTLN is. **Never guess account information.**
3. Test passwordless login:
   `ssh -o BatchMode=yes -o ConnectTimeout=10 <host> 'echo OK && hostname'`.
4. On success, write `~/.config/tufts-hpc/config` (template in the header of
   `scripts/preflight.sh`) and `chmod 600` it. Also probe for research storage:
   `ssh <host> 'ls -d /cluster/tufts/*/$USER 2>/dev/null'` and record it in
   `HPC_RESEARCH_DIR` if present.
5. On failure, follow NO_PASSWORDLESS above; do not write `HPC_PASSWORDLESS=yes`.

## 1. Compliance red lines (each one is a hard constraint)

1. **Login nodes are for light operations only**: ls / cat / squeue / sbatch /
   editing small files / small scp. Anything that burns CPU, memory, or heavy IO —
   installing packages, building conda/uv environments, extracting large archives,
   bulk-deleting big directories, compressing, data processing, running any
   program — **must go through a compute node**:
   ```bash
   # Interactive (for a sequence of manual steps; QOS caps at 4 hours)
   ssh -t "$HPC_HOST" 'srun -p batch -t 0-1:00:00 -c 4 --mem=8G --pty bash'
   # One-shot (for automation: wrap a single heavy command in srun)
   ssh "$HPC_HOST" 'srun -p batch -t 0-0:30:00 -c 2 --mem=4G bash -c "cd ~/proj && tar xzf data.tar.gz"'
   ```
   All nodes share the same storage (home and /cluster), so work done on any
   compute node is visible everywhere — nodes differ only in compute power.
   "Borrowing a compute node for chores" has zero downside; don't hesitate.
2. **Every HPC action must trace back to an explicit user request.** Once the user
   says "run X on the HPC", the deploy → submit → monitor → retrieve chain for
   that task can run autonomously; actions outside that scope (touching other
   directories, cancelling unrelated jobs) are off-limits.
3. **Destructive operations require a confirmed list first**: bulk `rm`,
   overwriting existing remote results, `scancel` on jobs not submitted in this
   task.
4. **Rate-limit polling**: status-check loops at ≥ 60-second intervals (don't
   hammer squeue). Batch several remote commands into one ssh call
   (`ssh host 'cmd1; cmd2; cmd3'`) — fewer connections, and much lower latency
   through a jump host.
5. **Stay well below quota ceilings.** Before a large submission, check current
   load with `squeue --me | wc -l`. Per-user limits: batch+gpu combined ≤ 250
   CPUs / 10 GPUs; preempt ≤ 1000 CPUs / 20 GPUs. Throttle arrays with `%N`
   (e.g. `%200`).
6. **No restricted data on the cluster** (HIPAA, FERPA, etc.). Never store or
   enter passwords on the user's behalf.

## 2. Status checks (when the user asks "how are my jobs doing?")

Grab everything in one ssh call:

```bash
ssh "$HPC_HOST" 'squeue --me; echo ---; sacct -X --starttime today -o JobID,JobName%20,State,Elapsed,ExitCode | tail -30'
```

| To see | Command (inside ssh) |
|---|---|
| Running / queued jobs | `squeue --me` |
| Recent job outcomes (incl. failures) | `sacct -X --starttime <date> -o JobID,JobName%20,State,Elapsed,ExitCode` |
| Resource efficiency of a finished job | `seff <jobid>` |
| Storage quota | `quota -s` (home hard limit is "30GB", shown as ~28611M — MiB units; full = writes blocked) |
| Partition / node states | `sinfo` |
| GPU availability | `module load hpctools && hpctools` (interactive menu; for automation use `sinfo -p gpu -o "%n %G %t"`) |
| Job logs | `tail -50 <submit-dir>/slurm-<jobid>.out` (or the path set via `--output`) |

Failure triage order: tail of the `.err` file → `sacct` State/ExitCode (`OOM` →
more memory, `TIMEOUT` → more time, `NODE_FAIL`/`PREEMPTED` → just resubmit) →
`seff` to see whether resources were undersized.

## 3. Task routing

- **Deploying code / transferring files / setting up environments (conda, uv) /
  storage & quota issues** → read [references/deploy.md](references/deploy.md) first.
- **Writing SLURM scripts / submitting jobs / array-job experiment matrices /
  choosing partitions / debugging jobs** → read [references/slurm.md](references/slurm.md) first.
- Both at once (the common "run X on the HPC") → read both, execute in
  deploy → slurm order.

## 4. Using the HPC inside a loop (submit → wait → retrieve → iterate)

Standard loop skeleton:

1. Deploy changed files (full dependency-chain check, see deploy.md), then submit
   (see slurm.md).
2. Wait in the background, polling at ≥ 60s intervals (scale up to 5–10 minutes
   for long jobs):
   ```bash
   ssh "$HPC_HOST" 'squeue --me -h | wc -l'   # 0 = everything finished
   ```
   When the queue drains, immediately classify with `sacct` — COMPLETED vs
   FAILED vs PREEMPTED. An empty queue does not mean success.
3. Retrieve results: `rsync -azP "$HPC_HOST":<remote>/results/ ./results/`
   (incremental; safe to re-run).
4. Analyze locally → adjust code/parameters → back to 1. Re-run only the missing
   tasks using the idempotent submit pattern (slurm.md, "Idempotent submit
   pattern") — that pattern is what makes the whole loop safely re-entrant.

## 5. Key cluster facts (quick recall; details in references/)

- New cluster login: `login-prod.pax.tufts.edu` (load-balanced across
  login-p01/02/03). Hostnames without `-prod` belong to the old, retiring cluster.
- All public partitions cap at **2 days** (`2-00:00:00`). Partitions: `batch`
  (CPU only), `gpu` (must request `--gres`), `preempt` (most resources, but jobs
  can be preempted and are killed within ~30s — tasks must be idempotent /
  resumable).
- Home `/cluster/home/$USER` has a 30GB quota; conda environments and large data
  belong in research storage, not home.
- Conda: `module load miniforge/25.3.0` (there is **no** `module load python`).
- Interactive session QOS: max 4 hours, max 1 GPU.
