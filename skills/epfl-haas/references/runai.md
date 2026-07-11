# RunAI job submission on Haas: node pools, interactive vs batch, and the pitfalls that matter

Everything here assumes preflight passed, `HAAS_HOST` is loaded from
`~/.config/epfl-haas/config`, and `runai whoami` succeeds (SKILL.md §2).

RunAI has no SLURM-style partitions or array jobs — jobs are Kubernetes pods
scheduled across **node pools**, submitted and inspected via the `runai` CLI.

## 1. Node pools are not "any available GPU"

Do not assume a `default` node pool means "schedule on whichever GPU is
free" — on some EPFL RunAI setups it effectively pins to one specific GPU
class (e.g. a high-memory A100 pool). Before launching many jobs:

1. Decide the minimum acceptable GPU class for the experiment.
2. Inspect current node pools and their GPU classes — the exact command
   depends on the CLI generation (`runai nodepool list` on newer CLIs; check
   `runai list --help` / `runai --help` for what this cluster's version
   offers) rather than assuming a fixed set from a previous project.
3. Pass node pools explicitly and, where the CLI supports it, as an ordered
   priority list — prefer a compatible, less-contended pool when the job
   doesn't need the largest/most contended GPU class.
4. Distinguish **guaranteed** quota (a "deserved GPUs" style number) from
   **opportunistic** idle-borrowing capacity — plan long-running or
   preemption-sensitive jobs against the guaranteed lane, and only use
   opportunistic/preemptible capacity for short or checkpoint/resume-capable
   work.

## 2. Interactive pods vs batch jobs

- Use a long-lived **interactive** pod for development, debugging, and
  environment setup.
- Use a **batch** job (submit a command, pod exits on completion) for
  reproducible one-shot or sweep experiments.
- Keep both under the same PVC path contract and environment convention
  (deploy.md) so nothing drifts between interactive debugging and the batch
  run meant to reproduce it.
- For work that can be reclaimed at any time (opportunistic/preemptible
  capacity), only use it with an explicit checkpoint/resume contract in the
  job itself — a job with no resume logic should stay on guaranteed capacity.

## 3. Auto-delete completed jobs

Prefer setting the CLI's auto-deletion-after-completion option for routine
batch/interactive verification jobs, with a short retention window when the
job is mainly operational scaffolding (and a longer one only when
postmortem log inspection is still useful). Leave retention opt-in rather
than default, so `runai list jobs` stays focused on live or recent work
instead of filling up with stale `Succeeded` entries.

## 4. Idempotent job-matrix submission (missing-result scan)

RunAI has no array-job primitive, so the SLURM idempotent-array-submit
pattern becomes a scan-and-submit loop instead:

1. Keep the experiment matrix (envs/methods/seeds/shards) in exactly one
   config file that both the submit wrapper and each job's entrypoint read.
2. Before submitting, scan PVC-backed results for which task IDs already
   have a `.done` marker or checkpoint; submit RunAI jobs only for the
   missing ones.
3. Have each job's entrypoint early-exit if its own result marker already
   exists, and write that marker only on success as the last step.
4. Combine with auto-deletion (§3) so re-running the scan doesn't have to
   wade through stale `Succeeded` job objects to figure out what's missing.

Why: this makes resuming a sweep after an opportunistic/preemptible job gets
reclaimed free — re-run the submit wrapper, only the missing shards get
resubmitted — and avoids wasting GPU-hours (guaranteed or opportunistic) on
already-completed work.

Sketch:

```bash
# submit.sh — scan PVC results, submit only what's missing
for task_id in "${TASK_IDS[@]}"; do
  out="results/${task_id}.done"
  [[ -f "$out" ]] && continue
  runai submit "job-${task_id}" \
    --image <project-image> \
    --gpu 1 --cpu 4 --memory 16G \
    --run-as-uid <uid> --run-as-gid <gid> \
    --node-pools <ordered-pool-list> \
    --existing-pvc claimname=<claim-name>,path=<mount-path> \
    --command -- bash -lc "cd <mount-path>/project && ./run_task.sh ${task_id}"
done
```

```bash
# run_task.sh (inside the pod) — early-exit if already done
OUT="results/${1}.done"
[[ -f "$OUT" ]] && { echo "SKIP $OUT"; exit 0; }
.venv/bin/python src/train.py --task "$1"
touch "$OUT"
```

Adapt image/mount/command flags to the cluster's actual `runai submit`
syntax — verify current flag names against `runai submit --help` rather than
assuming these are stable across RunAI versions. Notes on the flags above:

- RunAI defaults to **0 GPUs** — omit `--gpu` and you get a CPU-only pod.
- Without `--run-as-uid`/`--run-as-gid` (find them with `id` on the SSH
  host), files the pod writes to the PVC come out root-owned — a classic
  newcomer trap.
- The old `--pvc <claim>:<mount>` syntax is deprecated (and its legacy format
  actually *created* a PVC); mounting an existing claim uses
  `--existing-pvc claimname=...,path=...` on current CLI versions.

## 5. Monitoring, debugging, cancelling

- `runai describe job <name>` — inspect events to distinguish node-pool
  saturation from project fair-share/quota, CPU/memory limits, or
  preemption. Treat this output as potentially sensitive (SKILL.md
  Compliance red lines #6) — it can echo the submit command and env vars.
- `runai logs <name>` — tail application-level output; combine with
  `describe` events when a job never leaves `Pending`.
- Treat `ContainerCreating`, long image pulls, and image-cache misses as
  node/image startup problems, not code failures — don't start debugging
  application code before the pod has actually started running it.
- `runai delete job <name>` — only ever delete jobs submitted for the
  current task unless the user explicitly asks otherwise.
- If `runai` commands start failing with an auth/token error, don't
  continue interpreting job status as if it were current — that's a
  `runai login` problem, not a job problem (SKILL.md §2).
