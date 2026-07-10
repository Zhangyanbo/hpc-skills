# Deployment, file transfer, environments, and storage

Everything here assumes preflight passed and `HPC_HOST` is loaded from
`~/.config/tufts-hpc/config`.

## 1. Where things go on the cluster

| Location | Quota | Use for |
|---|---|---|
| Home `/cluster/home/$USER` | 30GB **hard** limit | code, small configs, job scripts |
| Research `/cluster/tufts/<lab>/$USER` (`$HPC_RESEARCH_DIR`) | ≥50GB, expandable | conda envs, datasets, large results |

- If `HPC_RESEARCH_DIR` is empty in the config, the user has no lab storage —
  warn them before writing anything large, and suggest emailing
  tts-research@tufts.edu to request it.
- Home filling up is the #1 silent failure: writes get blocked cluster-wide for
  the user. Check `quota -s` before and after large installs or transfers.
- Cache cleanup commands (safe, re-downloadable): `rm -rf ~/.cache/uv`,
  `rm -rf ~/.cache/pip`, `conda clean --all -y`. Bulk deletes of big trees are
  heavy IO — run them on a compute node (see SKILL.md red line #1).
- Per-project remote roots: record each project's remote path in that project's
  CLAUDE.md the first time you deploy it. Note that local and remote directory
  names may differ (e.g. a local `deploy/` staging dir maps onto the remote
  project root) — never assume a 1:1 path mirror; check before scp'ing.

## 2. Deployment — the dependency-chain rule

The most common deployment failure: the SLURM script imports local modules whose
updated versions were never copied. The job then crashes within seconds, wasting
a queue wait. Before any submission:

1. List every source file the entry script transitively uses (imports, `source`d
   shell configs, data files read at startup).
2. Diff against what's on the cluster — at minimum, check which of those files
   have local modifications since the last deploy.
3. Transfer them **all**, then spot-check that the remote copy really changed:
   ```bash
   ssh "$HPC_HOST" "grep -n '<some string unique to the new version>' <remote>/src/foo.py"
   ```

### Transfer commands

`rsync` is preferred (incremental, resumable, preserves structure):

```bash
# Upload a project (note trailing slashes; --exclude keeps junk off the cluster)
rsync -azP --exclude '.git' --exclude '.venv' --exclude '__pycache__' \
    ./project/ "$HPC_HOST":~/research/project/

# Download results
rsync -azP "$HPC_HOST":~/research/project/results/ ./results/
```

`scp` is fine for a handful of files. Avoid OnDemand upload for automation
(browser-based, 976MB single-file limit). For very large datasets (>10GB),
suggest Globus to the user rather than tying up a login node for hours.

## 3. Python environments

### uv projects (pyproject.toml + uv.lock)

- **`pyproject.toml` and `uv.lock` are an atomic pair — always transfer both.**
  After changing dependencies: run `uv lock` locally *first*, then scp both files
  together, then run `uv sync` on the cluster. A missing `uv.lock` makes
  `uv sync` silently fail to install new packages.
- Never use `.venv/bin/pip install` on a uv project — it bypasses the lockfile.
- Run `uv sync` **on a compute node**, not the login node, and **never inside an
  array job** — hundreds of concurrent syncs each downloading packages will blow
  the storage quota instantly. Sync once, before submitting:
  ```bash
  ssh "$HPC_HOST" 'srun -p batch -t 0-0:30:00 -c 2 --mem=4G bash -c \
      "cd ~/research/project && module load miniforge/25.3.0 && uv sync"'
  ```
  Compute nodes may lack outbound internet. If downloads time out there, fall
  back to running *only* the download/sync step on the login node (it is mostly
  network IO — keep it brief), or ask the user.
- In SLURM scripts, invoke `.venv/bin/python` directly instead of `uv run`
  (concurrent `uv run` calls bloat the cache).
- uv is not preinstalled; if absent, `pip install --user uv` (on a compute node
  if possible).

### Conda environments

- Load with `module load miniforge/25.3.0` (recommended) or
  `module load anaconda/2025.06.0`. **`module load python` does not exist.**
- Environments and package cache belong in research storage, per official docs:
  ```bash
  conda config --add envs_dirs "$HPC_RESEARCH_DIR/condaenv"
  conda config --add pkgs_dirs "$HPC_RESEARCH_DIR/condapkg"
  ```
  Conda envs in home are the classic way to blow the 30GB quota.
- Create/modify envs on a compute node. Prefer `conda install`; use pip only for
  packages conda lacks, and never mix them for the same package.

### Headless rendering

For MuJoCo / gym rendering on GPU-less or display-less nodes:
`export MUJOCO_GL=egl` in the job script.

## 4. Standard "run X on the HPC" sequence

1. Preflight (SKILL.md §0).
2. Decide the remote root (project CLAUDE.md > `HPC_DEFAULT_REMOTE_ROOT`).
3. rsync the project (with excludes), including the full dependency chain.
4. First deploy only: set up the environment on a compute node (uv sync / conda
   create), then verify: `ssh "$HPC_HOST" '<remote>/.venv/bin/python -c "import <key_pkg>"'`.
5. Write/adjust the SLURM script → continue in [slurm.md](slurm.md).
6. After jobs finish: rsync results back, report outcomes honestly
   (COMPLETED/FAILED counts from `sacct`, not just "queue is empty").
