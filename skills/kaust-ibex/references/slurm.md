# SLURM on Ibex: scripts, GPU requests, interactive sessions, and the pitfalls that matter

Everything here assumes preflight passed and `IBEX_HOST` is loaded from
`~/.config/kaust-ibex/config`.

## 1. Partitions and limits

Ibex commonly exposes several GPU-oriented partitions with different time
limits and hardware mixes (e.g. a short debug lane, a general GPU lane, and
longer-running lanes with tighter time caps), plus a general CPU partition.
Do not hardcode a partition name, time limit, or assumed GPU generation from a
previous project — always verify live:

```bash
sinfo -o "%P %l %D %c %m %G"
```

Interactive sessions (`salloc`/`srun --pty`) are typically capped at a much
shorter wall time than batch partitions — check current limits rather than
assuming a fixed number.

When a job must target a specific GPU generation (e.g. A100 vs V100), request
it explicitly with `--constraint=<gpu-type>` or the cluster's equivalent
feature flag, and confirm the available feature/GRES strings against
`sinfo -o "%n %G %f %t"` for the target partition.

## 2. A minimal correct job script

```bash
#!/usr/bin/env bash
#SBATCH --job-name=<descriptive-name>
#SBATCH --partition=<gpu-partition>
#SBATCH --gres=gpu:1
#SBATCH --time=04:00:00
#SBATCH --mem=40G
#SBATCH --cpus-per-task=4
#SBATCH --output=logs/slurm-%j.out
set -euo pipefail

# PITFALL: SLURM copies this script before executing, so BASH_SOURCE / dirname
# "$0" may not point at your project. Always cd to the submit dir first, then
# use project-root-relative paths.
cd "${SLURM_SUBMIT_DIR}"

# Activate the environment explicitly — do not rely on .bashrc being sourced
# in a non-interactive SLURM shell.
source <path-to-conda-or-mamba-init-script>
conda activate <env-name>

.venv/bin/python src/train.py --seed 0
```

Key points:

- `--output`/`--error` paths are relative to the submit directory and their
  parent dirs must already exist (`mkdir -p logs` before sbatch), otherwise
  the job dies instantly with no log at all.
- Submit from the project root on the cluster:
  ```bash
  ssh "$IBEX_HOST" 'cd "$IBEX_PROJECT_ROOT"/project && mkdir -p logs && sbatch scripts/job.sh'
  ```
  Capture the printed `Submitted batch job <id>` — that job id scopes all
  later monitoring/cancelling for this task.

GPU jobs: request the GPU generation explicitly if the project depends on it,
and check availability first with `sinfo -p <partition> -o "%n %G %f %t"`.

## 3. Interactive sessions and persistent dev-server allocations

**Short interactive shells**: use `srun --pty` for quick validation or
debugging. Forcing a TTY at the SSH layer (`ssh -tt ...`) may be required for
`srun --pty` to behave correctly end-to-end — without it, some sites report
`--pty` degrading to a non-interactive session. Keep runtime/resource
requests small for this use case; prefer a short debug-style partition if the
site has one.

**Persistent development allocations**: for a longer-lived remote development
surface (e.g. hosting a remote IDE/code-server process on an allocated
compute node), submit a dedicated `sbatch` launcher that starts the service
and prints a connection recipe (typically an SSH tunnel from the local
machine to the allocated node's port), rather than repeatedly opening
one-off interactive shells for the same ongoing work. Treat launcher stdout
and any `slurm-<jobid>.out` for such jobs as potentially sensitive if they
can embed a generated access token or password — avoid pasting that output
into chat, docs, or commits.

Do not assume one mechanism replaces the other: `srun --pty`/`salloc` are for
short shells and validation; a dedicated launcher job is for a reusable,
reconnectable dev surface. Validate partition, feature, and node behavior
before recommending an interactive recipe as canonical for a given GPU type —
interactive access can behave differently across GPU generations/node
features on the same cluster.

## 4. Idempotent submit pattern (the recommended workflow skeleton)

Never raw-`sbatch` an experiment matrix. Route everything through a
`submit.sh` that scans for missing results and submits only those. Combined
with an early-exit in the job script ("result exists → exit 0"), this gives
free resume-after-preemption, crash recovery, and safe re-submission — which
is what makes iterate-loops re-entrant.

Three files, one source of truth:

**a) `experiment_config.sh` — the only place the matrix is defined**

```bash
#!/usr/bin/env bash
ENVS=( "env-a" "env-b" )
METHODS=( "baseline" "variant_a" )
N_SEEDS=20
BASE_SEED=0
```

**b) `submit.sh` — scan missing → submit only what's missing**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source "scripts/experiment_config.sh"

for env in "${ENVS[@]}"; do
  for met in "${METHODS[@]}"; do
    for ((s=0; s<N_SEEDS; s++)); do
      seed=$((BASE_SEED + s))
      out="results/${met}/${env}/seed_${seed}.done"
      [[ -f "$out" ]] && continue
      sbatch --export="ALL,ENV=${env},METHOD=${met},SEED=${seed}" scripts/job.sh
    done
  done
done
```

**c) `job.sh` — early-exit if already done**

```bash
#!/usr/bin/env bash
#SBATCH --job-name=exp-matrix
#SBATCH --partition=<gpu-partition>
#SBATCH --gres=gpu:1
#SBATCH --time=04:00:00
#SBATCH --output=logs/job_%j.out
set -euo pipefail
cd "${SLURM_SUBMIT_DIR}"

OUT="results/${METHOD}/${ENV}/seed_${SEED}.done"
[[ -f "$OUT" ]] && { echo "SKIP $OUT"; exit 0; }

.venv/bin/python src/train.py -e "$ENV" -m "$METHOD" -s "$SEED"
```

Adapt names/decoding to the actual experiment; keep the three structural
ideas: single config source, per-task missing-result scan, early-exit
idempotence. The job script must *create* the `.done`/result file only on
success (last step). For very large matrices, consider SLURM array jobs
instead of one `sbatch` per task — check the cluster's live `MaxArraySize`
and `--array` string-length limits with `sinfo`/site docs before assuming a
specific number.

## 5. Monitoring, debugging, cancelling

Prefer one combined ssh call (see SKILL.md §2 for the standard status
snapshot).

- Why is my job pending? The `NODELIST(REASON)` column: `(Priority)`/`(Resources)`
  = normal queueing; `(QOSMaxGRESPerUser)`/similar = at quota, wait; `(launch
  failed requeued held)` = something's wrong — inspect with
  `scontrol show job <id>`.
- Cancel: `scancel <jobid>`; only ever `scancel` jobs submitted for the
  current task unless the user explicitly asks otherwise.
- Interactive debugging of a failing job: reproduce on an interactive
  allocation (`srun --pty` or `salloc`, then run the command by hand) rather
  than iterating via `sbatch` round-trips.
