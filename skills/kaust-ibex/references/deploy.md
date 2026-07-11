# Deployment, file transfer, environments, and storage

Everything here assumes preflight passed and `IBEX_HOST` is loaded from
`~/.config/kaust-ibex/config`.

## 1. Where things go on the cluster

| Location | Use for |
|---|---|
| Login home `/home/<username>` (200 GB + a file-count quota) | code, small configs, job scripts, ssh keys |
| Durable project storage `/ibex/user/<username>` (1.5 TB per user; `$IBEX_PROJECT_ROOT`) | conda/uv envs, datasets, checkpoints, results |
| `/tmp` on the login/frontend host | local temporary storage only — never durable |

- Do not conflate `/home/<username>` (login home; note the **file-count
  quota** — many small files, e.g. a conda env, can hit it before the byte
  quota) with `/ibex/user/<username>` (the durable project root) — they live
  on different filesystems with different characteristics.
- Storage on the project filesystem can run close to capacity across the
  whole cluster's users; check usage (`df -h /ibex/user` or the cluster's
  official quota tool) before large writes, and clean caches
  (`rm -rf ~/.cache/uv`, `rm -rf ~/.cache/pip`, `conda clean --all -y`) when
  space is tight. Bulk deletes of big trees are heavy IO — run them on a
  compute node, not the login node.
- Per-project remote roots: record each project's remote path in that
  project's CLAUDE.md the first time you deploy it. Local and remote
  directory names may differ — never assume a 1:1 path mirror; check before
  scp'ing.

## 2. Deployment — the dependency-chain rule

The most common deployment failure: the SLURM script imports local modules
whose updated versions were never copied. The job then crashes within
seconds, wasting a queue wait. Before any submission:

1. List every source file the entry script transitively uses (imports,
   sourced shell configs, data files read at startup).
2. Diff against what's on the cluster — at minimum, check which of those
   files have local modifications since the last deploy.
3. Transfer them **all**, then spot-check that the remote copy really
   changed:
   ```bash
   ssh "$IBEX_HOST" "grep -n '<some string unique to the new version>' <remote>/src/foo.py"
   ```

### Transfer commands

`rsync` is preferred (incremental, resumable, preserves structure):

```bash
# Upload a project (note trailing slashes; --exclude keeps junk off the cluster)
rsync -azP --exclude '.git' --exclude '.venv' --exclude '__pycache__' \
    ./project/ "$IBEX_HOST":"$IBEX_PROJECT_ROOT"/project/

# Download results
rsync -azP "$IBEX_HOST":"$IBEX_PROJECT_ROOT"/project/results/ ./results/
```

`scp` is fine for a handful of files. For code, prefer syncing through git
(push locally → pull on Ibex) so both sides can be verified with
`git rev-parse --short HEAD` — this is more auditable than blind rsync for
project code.

## 3. Python environments

### Conda / mamba environments

- Ibex provides a module-based conda/mamba stack; load it explicitly rather
  than assuming `python`/`conda` are already on `$PATH` in a non-interactive
  shell — check current module names with `module avail` (module names change
  between site software refreshes; don't assume a fixed name from an old
  project).
- Create/modify environments on a compute node (`salloc`/`srun --pty`), not
  the login node — package installs and solves are heavy IO/CPU operations.
- Keep environments and package caches on `/ibex/user/<username>`, not
  `/home` — conda envs in home are a classic way to blow a small home quota.

### uv projects (pyproject.toml + uv.lock)

- **`pyproject.toml` and `uv.lock` are an atomic pair — always transfer
  both.** After changing dependencies: run `uv lock` locally *first*, then
  sync both files together, then run `uv sync` on the cluster. A missing
  `uv.lock` makes `uv sync` silently fail to install new packages.
- Run `uv sync` on a compute node, not the login node, and never inside a
  large concurrent job fan-out — many concurrent syncs each downloading
  packages can blow the storage quota or thrash shared filesystem IO. Sync
  once, before submitting the batch.
- In SLURM scripts, invoke `.venv/bin/python` directly instead of `uv run`
  where many jobs may run concurrently.
- uv is not preinstalled on most HPC login nodes; if absent, install it on a
  compute node rather than the login node.

## 4. Standard "run X on Ibex" sequence

1. Preflight (SKILL.md §0).
2. Decide the remote root (project CLAUDE.md > `IBEX_PROJECT_ROOT`).
3. Sync the project (git push/pull, or rsync with excludes for non-code
   assets), including the full dependency chain.
4. First deploy only: set up the environment on a compute node (`uv sync` /
   conda create), then verify:
   `ssh "$IBEX_HOST" '<remote>/.venv/bin/python -c "import <key_pkg>"'`.
5. Write/adjust the SLURM script → continue in [slurm.md](slurm.md).
6. After jobs finish: rsync results back, report outcomes honestly
   (COMPLETED/FAILED counts from `sacct`, not just "queue is empty").
