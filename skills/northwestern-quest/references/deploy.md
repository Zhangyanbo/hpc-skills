# Deployment, file transfer, environments, and storage

Everything here assumes preflight passed and `QUEST_HOST` is loaded from
`~/.config/quest-hpc/config`.

## 1. Where things go on the cluster

| Location | Quota | Use for |
|---|---|---|
| Login home `/home/<netid>` | 80 GB, per-user | code, small configs, job scripts, ssh keys |
| Project allocation `/projects/<allocationID>` (`$QUEST_ALLOCATION_ROOT`) | Set per PI allocation (typically 1–2 TB); **shared by all allocation members** | conda/uv envs, datasets, checkpoints, results |
| `/scratch/<netid>` (`$QUEST_SCRATCH_ROOT`) | 5 TB, but **auto-purged** (files unmodified for ~30 days) | temporary large intermediate outputs only |

- If `QUEST_ALLOCATION_ROOT` is empty in the config, the user has no project
  allocation yet — warn them before writing anything large, and suggest they
  confirm allocation details with their PI or Northwestern Research Computing.
- Home filling up is a common silent failure. Keep conda/uv envs and large data
  out of `/home` — they belong in the project allocation.
- Never treat `/scratch` as durable: anything that must survive past the purge
  window (checkpoints, final results) belongs in the project allocation.
- Per-project remote roots: record each project's remote path in that project's
  CLAUDE.md the first time you deploy it. Local and remote directory names may
  differ — never assume a 1:1 path mirror; check before scp'ing.

## 2. Deployment — the dependency-chain rule

The most common deployment failure: the SLURM script imports local modules whose
updated versions were never copied. The job then crashes within seconds, wasting
a queue wait. Before any submission:

1. List every source file the entry script transitively uses (imports, sourced
   shell configs, data files read at startup).
2. Diff against what's on the cluster — at minimum, check which of those files
   have local modifications since the last deploy.
3. Transfer them **all**, then spot-check that the remote copy really changed:
   ```bash
   ssh "$QUEST_HOST" "grep -n '<some string unique to the new version>' <remote>/src/foo.py"
   ```

### Transfer commands

`rsync` is preferred (incremental, resumable, preserves structure):

```bash
# Upload a project (note trailing slashes; --exclude keeps junk off the cluster)
rsync -azP --exclude '.git' --exclude '.venv' --exclude '__pycache__' \
    ./project/ "$QUEST_HOST":"$QUEST_ALLOCATION_ROOT"/project/

# Download results
rsync -azP "$QUEST_HOST":"$QUEST_ALLOCATION_ROOT"/project/results/ ./results/
```

`scp` is fine for a handful of files. For code, prefer syncing through git
(push locally → pull on Quest) so both sides can be verified with
`git rev-parse --short HEAD` — this is more auditable than blind rsync for
project code, and it's the workflow most PI groups on Quest already expect.

## 3. Python environments

### Conda / mamba environments

- Quest provides a module-based conda/mamba stack; load it explicitly rather
  than assuming `python`/`conda` are already on `$PATH` in a non-interactive
  shell — check current module names with `module avail` (mamba/anaconda
  module names change between Quest software refreshes).
- Create/modify environments on a compute node (`salloc`), not the login node —
  package installs and solves are heavy IO/CPU operations.
- Keep environments and package caches on the project allocation, not `/home`.

### uv projects (pyproject.toml + uv.lock)

- **`pyproject.toml` and `uv.lock` are an atomic pair — always transfer both.**
  After changing dependencies: run `uv lock` locally *first*, then sync both
  files together, then run `uv sync` on the cluster. A missing `uv.lock` makes
  `uv sync` silently fail to install new packages.
- Run `uv sync` on a compute node, not the login node, and never inside a large
  concurrent job fan-out — many concurrent syncs each downloading packages can
  blow the storage quota or thrash shared filesystem IO. Sync once, before
  submitting the batch.
- In SLURM scripts, invoke `.venv/bin/python` directly instead of `uv run`
  where many jobs may run concurrently (avoids repeated cache-resolution
  overhead under concurrency).
- Watch for version conflicts between the CUDA-linked PyTorch stack and
  numpy/Python version choices — pin explicitly rather than letting resolvers
  pick the newest compatible set, especially when a project must run across
  more than one GPU generation.

## 4. Standard "run X on Quest" sequence

1. Preflight (SKILL.md §0).
2. Decide the remote root (project CLAUDE.md > `QUEST_ALLOCATION_ROOT`).
3. Sync the project (git push/pull, or rsync with excludes for non-code assets),
   including the full dependency chain.
4. First deploy only: set up the environment on a compute node (`uv sync` /
   conda create), then verify: `ssh "$QUEST_HOST" '<remote>/.venv/bin/python -c "import <key_pkg>"'`.
5. Write/adjust the SLURM script → continue in [slurm.md](slurm.md).
6. After jobs finish: rsync results back, report outcomes honestly
   (COMPLETED/FAILED counts from `sacct`, not just "queue is empty").
