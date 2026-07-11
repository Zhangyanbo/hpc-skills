# Deployment, file transfer, environments, and PVC storage

Everything here assumes preflight passed and `HAAS_HOST` is loaded from
`~/.config/epfl-haas/config`.

## 1. Where things go on the cluster

| Location | Use for |
|---|---|
| Control-plane login home | small configs, ssh keys — never anything a pod needs at runtime |
| PVC-backed project root (`$HAAS_PVC_ROOT`) | code, virtualenvs/conda envs, data caches, checkpoints, results — anything that must survive a pod restart |
| Container root filesystem (inside a pod, off-PVC) | scratch only — **does not persist** across pod restarts |

- Treat the PVC as the *only* durable storage layer. Never assume a change to
  the container filesystem outside the PVC-backed path will still be there
  next time the pod (re)starts.
- Define an explicit per-project path contract instead of relying on one
  fixed shared layout: a project root, plus derived data/outputs/assets
  subdirectories, all under the PVC.
- Define cache paths explicitly per project (`HF_HOME`,
  `HUGGINGFACE_HUB_CACHE`, `TRANSFORMERS_CACHE`, `UV_CACHE_DIR`, etc.) rather
  than assuming a fixed shared cache convention — it's fine for different
  projects to choose different layouts as long as each choice is explicit and
  PVC-backed.

## 2. Deployment — the dependency-chain rule

The most common deployment failure: a submitted job's entrypoint imports
local modules or reads config whose updated versions were never synced to
the PVC. The pod then fails minutes into a queued/scheduled run, wasting
scheduling time. Before any submission:

1. List every source file the entry script transitively uses (imports,
   sourced shell configs, data files read at startup).
2. Confirm the PVC-backed copy actually reflects the latest local change —
   e.g. `git status`/`git log` from a shell that mounts the same PVC (the
   control-plane host, or an interactive pod), not just "I pushed to git
   locally."
3. Transfer/sync anything stale, then spot-check with a `grep` for a string
   unique to the new version.

### Transfer / sync

Prefer syncing code through git (push locally → pull on the PVC-backed
project root from the control-plane host or an interactive pod) so both
sides can be verified with `git rev-parse --short HEAD`. For data/assets
that don't belong in git, `rsync` from a host that mounts the PVC:

```bash
rsync -azP --exclude '.git' --exclude '.venv' --exclude '__pycache__' \
    ./project/ "$HAAS_HOST":"$HAAS_PVC_ROOT"/project/
```

## 3. Python environments

### PVC-persistent uv workflow

- Keep `uv`, `UV_CACHE_DIR`, and `.venv/` on PVC-backed storage.
- Set `UV_PYTHON_INSTALL_DIR` and `UV_PROJECT_ENVIRONMENT` explicitly to
  PVC-backed paths for RunAI jobs — don't let uv fall back to a pod-local or
  ambiguous default env that disappears on pod restart.
- Choose environment granularity deliberately: a shared env for sequential
  work with stable dependencies, a stage-level env for parallel sweeps with
  stable dependencies, and a job-specific env only when isolation or
  dependency changes require it. Don't derive a brand-new env for every job
  name or one-off smoke test — that leads to unbounded env proliferation.
- Before deleting an old env, confirm no active RunAI job still references
  that exact path in its command or `UV_PROJECT_ENVIRONMENT`.
- When checking PVC storage pressure from many similar envs, don't multiply
  one env's apparent size by env count — same-dependency envs frequently
  share large files via hard links; measure actual marginal usage with
  multi-path `du`/`stat` before concluding cleanup is urgent.

### Conda environments

- Same PVC-persistence principle applies: keep the env directory and package
  cache on PVC-backed storage, not the pod's ephemeral root filesystem.

## 4. Runtime resolution — don't judge from the control-plane shell

The control-plane host's default Python is a login/control-plane
convenience, not the experiment runtime, and may not have your project's
dependencies (e.g. no `torch`). That is expected and is not itself a
blocker:

- First resolve the project-specific execution contract: repo wrapper,
  `UV_PROJECT_ENVIRONMENT`, project `.venv`, or a named conda env.
- Importing a package like `torch` can be sanity-checked from the
  control-plane host *inside the project's env*, but GPU/CUDA availability
  (`torch.cuda.is_available()`) is only meaningful inside an allocated RunAI
  GPU pod — don't infer GPU-side compatibility from a control-plane check.
- If the selected project env is missing a dependency, repair it via the
  project's lockfile/setup on PVC-backed storage; don't install into system
  Python on the control-plane host, and don't abandon the task before trying
  the actual project env.
- For GPU-specific compatibility questions, submit a short disposable RunAI
  job with an explicit node-pool request and auto-deletion rather than
  guessing from the control-plane host.

## 5. Standard "run X on Haas" sequence

1. Preflight (SKILL.md §0), then confirm `runai whoami` (SKILL.md §2).
2. Decide the PVC project root (project CLAUDE.md > `HAAS_PVC_ROOT`).
3. Sync the project (git push/pull, or rsync for non-code assets) onto the
   PVC, including the full dependency chain.
4. First deploy only: set up the environment inside a pod or via an
   interactive session (not the bare control-plane shell), then verify
   imports work inside that env.
5. Write/adjust the RunAI submit command → continue in [runai.md](runai.md).
6. After jobs finish: sync results back, report outcomes honestly
   (Succeeded/Failed counts from `runai list jobs`, not just "nothing is
   Running anymore").
