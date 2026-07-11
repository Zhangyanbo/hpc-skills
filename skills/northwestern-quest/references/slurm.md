# SLURM on Quest: scripts, GPU requests, and the pitfalls that matter

Everything here assumes preflight passed and `QUEST_HOST` is loaded from
`~/.config/quest-hpc/config`.

## 1. Partitions and limits

Quest's partition names and GPU hardware mix are allocation-specific — a PI
group's GPU pool (commonly something like `gengpu`) can include more than one
GPU generation (e.g. A100 and H100) in the same partition. Do not hardcode a
partition name or assume a fixed time/GPU limit from a previous project; always
verify live:

```bash
sinfo -o "%P %l %D %c %m %G"
```

When a job must target a specific GPU generation, request it explicitly rather
than relying on the partition default, e.g. `--gres=gpu:a100:1` or
`--gres=gpu:h100:1`, and confirm the requested GRES string against
`sinfo -o "%n %G %t"` for the target partition — the exact GRES type strings are
allocation/cluster-config dependent.

## 2. A minimal correct job script

```bash
#!/usr/bin/env bash
#SBATCH --account=<allocation>
#SBATCH --partition=<gpu-partition>
#SBATCH --gres=gpu:1
#SBATCH --time=04:00:00
#SBATCH --mem=40G
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --job-name=<descriptive-name>
#SBATCH --output=logs/slurm-%j.out
set -euo pipefail

# PITFALL: SLURM copies this script before executing, so BASH_SOURCE / dirname
# "$0" may not point at your project. Always cd to the submit dir first, then
# use project-root-relative paths.
cd "${SLURM_SUBMIT_DIR}"

.venv/bin/python src/train.py --seed 0
```

This example uses a uv-managed `.venv` (invoking `.venv/bin/python` directly,
per §5 of deploy.md — do not mix this with `conda activate`, since calling the
venv interpreter by absolute path bypasses whatever conda env was just
activated). If the project uses conda/mamba instead, activate it explicitly
and call `python` (not `.venv/bin/python`), never both in the same script:

```bash
source <path-to-conda-or-mamba-init-script>
conda activate <env-name>
export PYTHONNOUSERSITE=1
python src/train.py --seed 0
```

Key points:

- `--output`/`--error` paths are relative to the submit directory and their
  parent dirs must already exist (`mkdir -p logs` before sbatch), otherwise the
  job dies instantly with no log at all.
- Submit from the project root on the cluster:
  ```bash
  # $QUEST_ALLOCATION_ROOT is a *local* config value — expand it locally
  # (double quotes), never inside remote single quotes where it is undefined.
  ssh "$QUEST_HOST" "cd '$QUEST_ALLOCATION_ROOT/project' && mkdir -p logs && sbatch scripts/job.sh"
  ```
  Capture the printed `Submitted batch job <id>` — that job id scopes all
  later monitoring/cancelling for this task.

GPU jobs: request the GPU generation explicitly if the project depends on it
(older CUDA/torch stacks may not run correctly on newer GPU generations, or
vice versa); check availability first with `sinfo -p <partition> -o "%n %G %t"`.

## 3. Interactive sessions for debugging

For short debugging or environment setup, request an interactive allocation —
on Quest, `srun`/`salloc` **require `--account` and `--partition`**:

```bash
ssh "$QUEST_HOST" 'srun --account=<allocationID> --partition=short --time=1:00:00 -c 2 --mem=4G --pty bash'
```

If an interactive allocation from a previous task is *already running* (check
`squeue -u <netid>` for RUNNING jobs with a bash/interactive command and note
their NodeList), reuse it via `ssh <node>` instead of requesting a new one.
Verify the node's GPUs are genuinely idle before reusing:

```bash
ssh "$QUEST_HOST" "ssh <node> 'nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader'"
```

**Never keep idle interactive allocations alive as "placeholders" to skip the
queue** — holding GPUs you are not using is exactly the behavior that draws
administrator attention, and it also counts against your per-user GPU quota
(`QOSMaxGRESPerUser` or similar), blocking your own `sbatch` jobs. Release an
interactive allocation (`exit` / `scancel`) as soon as the debugging session
is done.

## 4. Background processes without tmux

`tmux` may not be available on Quest compute nodes (check with `command -v
tmux`). If it is absent, for a long-running process that must survive an SSH
disconnect on an interactive allocation, use:

```bash
# QUEST_ALLOCATION_ROOT is a *local* config value — interpolate it locally
# before it reaches the remote shell; it is not defined in the node's
# environment, so a literal "\$QUEST_ALLOCATION_ROOT" inside the remote
# quoting would expand to empty on the node.
ssh "$QUEST_HOST" "ssh <node> 'nohup bash -c \"
  source <conda-init-script>
  conda activate <env>
  cd ${QUEST_ALLOCATION_ROOT}/project
  python train.py <args>
\" </dev/null >${QUEST_ALLOCATION_ROOT}/project/logs/<run>.log 2>&1 & disown; sleep 2; ps aux | grep train | grep -v grep'"
```

Verify after launch: process alive (`ps aux | grep <script>`), GPU active
(`nvidia-smi`), and tail the log — an empty queue or a `RUNNING` squeue entry
does not by itself mean the process is doing useful work.

## 5. Idempotent submit pattern (the recommended workflow skeleton)

Never raw-`sbatch` an experiment matrix. Route everything through a `submit.sh`
that scans for missing results and submits only those. Combined with an
early-exit in the job script ("result exists → exit 0"), this gives free
resume-after-preemption, crash recovery, and safe re-submission — which is what
makes iterate-loops re-entrant.

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
#SBATCH --account=<allocation>
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

Adapt names/decoding to the actual experiment; keep the three structural ideas:
single config source, per-task missing-result scan, early-exit idempotence.
The job script must *create* the `.done`/result file only on success (last
step). For very large matrices, consider SLURM array jobs instead of one
`sbatch` per task — check the cluster's live `MaxArraySize` with
`scontrol show config | grep -i maxarraysize` before assuming a specific number.

## 6. Monitoring, debugging, cancelling

Prefer one combined ssh call (see SKILL.md §2 for the standard status
snapshot).

- Why is my job pending? The `NODELIST(REASON)` column: `(Priority)`/`(Resources)`
  = normal queueing; `(QOSMaxGRESPerUser)` = at GPU quota, wait or free a
  placeholder; `(launch failed requeued held)` = something's wrong — inspect
  with `scontrol show job <id>`.
- Cancel: `scancel <jobid>`; only ever `scancel` jobs submitted for the current
  task unless the user explicitly asks otherwise.
- Interactive debugging of a failing job: reproduce on an interactive
  allocation (`salloc`, then run the command by hand) rather than iterating via
  `sbatch` round-trips.
