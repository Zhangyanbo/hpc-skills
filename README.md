# HPC Skills

Skills that teach AI coding agents (such as [Claude Code](https://claude.com/claude-code)) how to use **university HPC clusters** for you — safely and by the rules.

Once a skill is installed, you can simply tell your agent things like:

> "Run this training script on the HPC."
>
> "How are my cluster jobs doing?"
>
> "Grab the results back and plot them."

…and the agent handles the rest: uploading your code, setting up the environment, writing and submitting SLURM jobs, watching the queue, and downloading the results — while strictly following your cluster's rules of conduct.

## Available skills

| School | Skill | Notes |
|---|---|---|
| Tufts University | [`skills/tufts-hpc/`](skills/tufts-hpc/) | SLURM cluster (`login-prod.pax.tufts.edu`); includes a beginner-friendly companion manual in Chinese under [`manual/`](manual/) |
| Northwestern University | [`skills/northwestern-quest/`](skills/northwestern-quest/) | Quest SLURM cluster; per-PI GPU allocations spanning multiple GPU generations, `/scratch` auto-purge, and an idempotent submit pattern for experiment matrices |
| KAUST | [`skills/kaust-ibex/`](skills/kaust-ibex/) | Ibex SLURM cluster; multi-generation GPU partitions (A100/V100), persistent dev-server-style allocations, idempotent submit pattern for experiment matrices |

Every cluster has its own quirks — module names, partition limits, storage quotas, scheduler settings that generic tutorials never mention. Each skill here captures those hard-won details for one specific cluster.

## Install

1. Clone this repository.
2. Copy your school's skill folder into your agent's skills directory. For Claude Code:

   ```bash
   cp -r /path/to/this-repo/skills/tufts-hpc ~/.claude/skills/
   ```

3. That's it. The next time you mention the HPC, the agent picks the skill up automatically.

## First use

The skills never store personal information in this repository. On first use, a skill walks you through creating a small private config file on your own machine (e.g. `~/.config/tufts-hpc/config`) holding your SSH host and username.

Two things you need:

- **An account on your cluster** (for Tufts: a UTLN and access to `login-prod.pax.tufts.edu`).
- **Passwordless SSH** (key-based login). The skill checks this automatically and tells you how to set it up if it's missing — without it, the agent can't operate unattended.

## Safety

These skills treat cluster policy as their highest priority. They are built to *never* get you in trouble:

- No computation on login nodes — heavy work always goes through a compute node.
- Gentle on the scheduler: status polling is rate-limited, commands are batched.
- Stays well below job and storage quotas.
- Destructive actions (bulk deletes, cancelling jobs) always ask you first.
- Your credentials never leave your machine, and never enter this repository.

## Contributing: add your school

Contributions are very welcome! If you've figured out your own cluster's quirks, turn them into a skill so everyone at your school (and their agents) can benefit:

1. Create `skills/<your-school>-hpc/` following the structure of [`skills/tufts-hpc/`](skills/tufts-hpc/): a `SKILL.md` (connection preflight + compliance rules + task routing), `references/` for the details, and a `scripts/preflight.sh`.
2. Keep it **fully de-sensitized** — no usernames, hostnames aliases, or personal paths. All account details belong in the user's local config file (`~/.config/<skill-name>/config`), never in the repo.
3. Capture what generic SLURM tutorials don't: your cluster's module names, partition/QoS limits, array-job caps, storage layout, and the local etiquette that keeps accounts in good standing.
4. Open a pull request.

## License

[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Cluster-specific information is based on each school's official HPC documentation (for Tufts: [rtguides.it.tufts.edu/hpc](https://rtguides.it.tufts.edu/hpc/)), whose copyright belongs to the respective university.
