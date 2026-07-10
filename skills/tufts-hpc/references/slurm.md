# SLURM on Tufts HPC: scripts, arrays, and the pitfalls that matter

Everything here assumes preflight passed and `HPC_HOST` is loaded from
`~/.config/tufts-hpc/config`.

## 1. Partitions and limits

| Partition | Time cap | Notes |
|---|---|---|
| `batch` | 2 days | Default, CPU only — GPU requests are rejected |
| `gpu` | 2 days | Must request `--gres=gpu:N`; CPU-only jobs are rejected |
| `preempt` | 2 days | Largest pool (includes lab-owned nodes), but jobs can be **preempted** — killed within ~30s. Only use with idempotent/resumable tasks |

Per-user quotas: batch+gpu combined ≈ 250 CPUs / 5000GB RAM / 10 GPUs;
preempt ≈ 1000 CPUs / 8000GB RAM / 20 GPUs. Submitting to `-p batch,preempt`
lets SLURM use whichever opens first and raises total concurrency.
Interactive sessions (`srun --pty bash`): max 4 hours, 1 GPU.
When exact numbers matter, verify live: `sinfo -o "%P %l %D %c %m"`.

## 2. A minimal correct job script

```bash
#!/usr/bin/env bash
#SBATCH --job-name=myexp
#SBATCH --partition=batch
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=1-00:00:00
#SBATCH --output=results/slurm/job_%j.out
#SBATCH --error=results/slurm/job_%j.err
set -euo pipefail

module load miniforge/25.3.0

# PITFALL: SLURM copies this script to /var/spool/slurm/... before executing,
# so BASH_SOURCE / dirname "$0" point at the copy, not your project. Always cd
# to the submit dir first, then use project-root-relative paths.
cd "${SLURM_SUBMIT_DIR}"

.venv/bin/python src/train.py --seed 0
```

Key points:
- `--output`/`--error` paths are relative to the submit directory and their
  parent dirs must already exist (`mkdir -p results/slurm` before sbatch),
  otherwise the job dies instantly with no log at all.
- Default output (if unset) is `slurm-<jobid>.out` in the submit dir.
- `.venv/bin/python`, not `uv run` (cache bloat under concurrency — deploy.md §3).
- Submit from the project root on the cluster:
  ```bash
  ssh "$HPC_HOST" 'cd ~/research/project && mkdir -p results/slurm && sbatch src/scripts/job.sh'
  ```
  Capture the printed `Submitted batch job <id>` — that job id scopes all
  later monitoring/cancelling for this task.

GPU jobs: `--partition=gpu --gres=gpu:1`; optionally pin a model with
`--constraint` (e.g. `a100`). Check availability first:
`sinfo -p gpu -o "%n %G %t"`.

## 3. Array jobs — Tufts-specific hard limits

Three constraints that generic SLURM tutorials never mention:

1. **`MaxArraySize = 2000`** — max array index is 1999, and ~1000 jobs per user.
   A 5440-task matrix cannot be `--array=0-5439`.
2. **The `--array` string itself has a length cap.** Listing 1000+ comma-separated
   IDs fails with "Pathname ... too long". Never enumerate IDs in `--array`.
3. Both are solved the same way: **a task-list file + contiguous ranges.**
   Write real task IDs (one per line) to a file; `--array=0-(N-1)` indexes into
   that file; batches beyond 2000 get an offset via `--export=ALL,TASK_OFFSET=k`.

## 4. Idempotent submit pattern (the recommended workflow skeleton)

Never raw-sbatch an experiment matrix. Route everything through a `submit.sh`
that scans for missing results and submits only those. Combined with an
early-exit in the job script ("result exists → exit 0"), this gives free
resume-after-preemption, crash recovery, and safe re-submission — which is what
makes iterate-loops re-entrant.

Three files, one source of truth:

**a) `experiment_config.sh` — the only place the matrix is defined**

```bash
#!/usr/bin/env bash
ENVS=( "CartPole-v1" "Acrobot-v1" )
METHODS=( "baseline" "variant_a" )
N_SEEDS=20
BASE_SEED=0
```

**b) `submit.sh` — scan missing → write task list → batched sbatch**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."          # project root; BASH_SOURCE works fine here
source "src/scripts/experiment_config.sh"

N_ENVS=${#ENVS[@]}; N_MET=${#METHODS[@]}
TOTAL=$((N_ENVS * N_MET * N_SEEDS))

# Collect task IDs whose result file does not exist yet
missing_ids=()
for ((task=0; task<TOTAL; task++)); do
  seed_idx=$((task / (N_ENVS * N_MET)))
  rem=$((task % (N_ENVS * N_MET)))
  env="${ENVS[$((rem / N_MET))]}"
  met="${METHODS[$((rem % N_MET))]}"
  seed=$((BASE_SEED + seed_idx))
  [[ -f "results/${met}/${env}/seed_${seed}.done" ]] || missing_ids+=("$task")
done
echo "missing: ${#missing_ids[@]} / $TOTAL"
(( ${#missing_ids[@]} == 0 )) && exit 0

# Real IDs go into a file; --array only ever gets a contiguous range
mkdir -p results/slurm
printf '%s\n' "${missing_ids[@]}" > results/slurm/pending_tasks.txt

# Batch by 2000 (MaxArraySize), offset via TASK_OFFSET; %200 throttles concurrency
N=${#missing_ids[@]}; MAX=2000
for ((c=0; c*MAX<N; c++)); do
  off=$((c*MAX)); size=$((N-off)); (( size>MAX )) && size=$MAX
  sbatch -p batch,preempt --export="ALL,TASK_OFFSET=${off}" \
         --array="0-$((size-1))%200" src/scripts/job_array.sh
done
```

**c) `job_array.sh` — remap index, decode, early-exit**

```bash
#!/usr/bin/env bash
#SBATCH --job-name=exp-matrix
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=1-00:00:00
#SBATCH --output=results/slurm/job_%A_%a.out
#SBATCH --error=results/slurm/job_%A_%a.err
set -euo pipefail

module load miniforge/25.3.0
cd "${SLURM_SUBMIT_DIR}"                       # BASH_SOURCE is unusable here
source "src/scripts/experiment_config.sh"

# Array index → real task ID via the task list (+ batch offset)
TASK_OFFSET=${TASK_OFFSET:-0}
if [[ -f results/slurm/pending_tasks.txt ]]; then
  TASK_ID=$(sed -n "$((SLURM_ARRAY_TASK_ID + TASK_OFFSET + 1))p" results/slurm/pending_tasks.txt)
else
  TASK_ID=${SLURM_ARRAY_TASK_ID}               # fallback for direct sbatch
fi

N_ENVS=${#ENVS[@]}; N_MET=${#METHODS[@]}
ENV="${ENVS[$(( (TASK_ID % (N_ENVS*N_MET)) / N_MET ))]}"
MET="${METHODS[$(( TASK_ID % N_MET ))]}"
SEED=$(( BASE_SEED + TASK_ID / (N_ENVS*N_MET) ))

# Idempotence: skip if done — enables resume after preemption/crash
OUT="results/${MET}/${ENV}/seed_${SEED}.done"
[[ -f "$OUT" ]] && { echo "SKIP $OUT"; exit 0; }

.venv/bin/python src/train.py -e "$ENV" -m "$MET" -s "$SEED"
```

Adapt names/decoding to the actual experiment; keep the three structural ideas:
single config source, task-list remapping, early-exit idempotence. The job
script must *create* the `.done`/result file only on success (last step).

## 5. Monitoring, debugging, cancelling

Prefer one combined ssh call (see SKILL.md §2 for the standard status snapshot).

- Array-aware overview: `squeue --me -o "%A %j %t %M %R"` — a pending array
  shows as one line `12345_[0-499%200]`.
- Why is my job pending? The `NODELIST(REASON)` column: `(Priority)`/`(Resources)`
  = normal queueing; `(QOSMaxCpuPerUserLimit)` = at quota, just wait;
  `(launch failed requeued held)` = something's wrong — inspect with
  `scontrol show job <id>`.
- Per-task outcomes for an array: `sacct -j <arrayid> -X -o JobID,State,ExitCode,Elapsed`.
- Cancel: `scancel <jobid>` (whole array) or `scancel <id>_<idx>`; only ever
  `scancel` jobs submitted for the current task unless the user explicitly asks.
- After preemption on `-p preempt`: nothing to clean up — re-run `submit.sh`;
  the missing-scan resubmits only what didn't finish.
- Interactive debugging of a failing job: reproduce on an interactive node
  (`srun -p batch -t 0-1:00:00 -c 4 --mem=8G --pty bash`, then run the python
  command by hand) rather than iterating via sbatch round-trips.
