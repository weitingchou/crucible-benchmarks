# Crucible Research

Performance analysis, system evaluation, and benchmarking of databases tested by the [Crucible](https://github.com/your-org/crucible) platform.

This repository hosts analytical tools, Jupyter notebooks, deployment scripts for Systems Under Test (SUTs), and autonomous research investigations that produce data-backed reports on database behavior under load.

Inspired by [autoresearch](https://github.com/SqueezeAILab/AutoResearch) — the idea that AI agents can autonomously design experiments, collect data, and synthesize findings. We apply the same philosophy to database performance engineering: define a hypothesis, let Claude run the experiments via Crucible, and get a report.

## Repository Structure

```
.
├── analysis/                       # Shared, engine-agnostic analytical tooling
│   ├── requirements.txt            # Python dependencies (pandas, matplotlib, jupyter)
│   ├── parsers/                    # Scripts to parse raw k6 CSVs and Prometheus metrics
│   └── notebooks/                  # Reusable Jupyter notebooks for cross-engine visualization
├── infra/                          # Shared infrastructure (Prometheus, etc.)
│   └── helm/prometheus/
├── targets/                        # Isolated folders per System Under Test (SUT)
│   └── doris/
│       ├── deploy/                 # Helm charts for reproducible SUT provisioning
│       ├── fixtures/               # Data generation configs, DDLs, workload SQL
│       └── research/               # Goal-driven research investigations
│           └── {goal}/
│               ├── goal.md         # Human-authored hypothesis and experiment design
│               ├── plans/          # Auto-generated Crucible test plan YAMLs
│               ├── results.yaml    # Structured log of every experiment run
│               └── report.md       # Auto-generated findings report
├── .claude/skills/research/        # The /research skill definition
├── CLAUDE.md
└── README.md
```

## Autonomous Research

The core workflow in this repo is **goal-driven autonomous research**. A human writes a hypothesis; Claude designs experiments, submits load tests to Crucible, collects metrics, and produces a findings report — all without manual intervention.

### How It Works

1. **Write a goal file** — Create `targets/{engine}/research/{goal}/goal.md` with your hypothesis, metrics of interest, experiment design, and success criteria.

2. **Run the research skill** — In Claude Code, invoke:
   ```
   /research targets/doris/research/join-spill-analysis/goal.md
   ```

3. **Claude executes the full loop:**
   - Reads the goal and understands the hypothesis
   - Designs experiments (which queries, concurrency levels, durations)
   - Uploads workloads and submits test runs to Crucible
   - Monitors progress, collects results as each run completes
   - Handles failures (restores crashed SUTs, retries only failed runs)
   - Analyzes data across experiments
   - Writes `results.yaml` (structured experiment log) and `report.md` (findings)

4. **Review the report** — Read `report.md`. If it doesn't fully answer your questions, give Claude feedback and it will run follow-up experiments targeting only the gaps.

### Goal File Template

```markdown
---
allow_deploy_changes: false   # set true to permit SUT config modifications
auto_approve: false           # set true to skip approval prompts
---

# {Title}

## Context
[Background that motivates the investigation]

## Engine
{engine name, e.g., doris}

## Hypothesis
[The specific claim to prove or disprove]

## Metrics of Interest
- {metric 1 — e.g., p99 query latency}
- {metric 2 — e.g., BE memory utilization}

## Suggested Metrics (optional)
[Specific PromQL queries for the observability block]

## Experiment Design
[Suggested approach — which parameters to vary, how many steps, etc.]

## Constraints
- {constraint 1}
- {constraint 2}

## Success Criteria
[What the final report must answer — bulleted list of specific questions]
```

### Example: CPU vs Concurrency Correlation

```bash
# The goal file defines the hypothesis:
# "BE CPU scales linearly at low concurrency but saturates at higher levels"
cat targets/doris/research/cpu-concurrency-correlation/goal.md

# Run the investigation
/research targets/doris/research/cpu-concurrency-correlation/goal.md

# Claude will:
# - Submit TPC-H workloads at concurrency 1, 2, 4, 8, 16, 32
# - Collect CPU, QPS, and latency metrics from Prometheus
# - Produce a report showing the saturation point and latency curve
```

## Manual Workflow

For ad-hoc analysis outside of the autonomous research loop:

1. **Deploy** — Provision SUTs via Helm charts in `targets/{engine}/deploy/`
2. **Execute** — Run Crucible load tests or use the workload SQL in `fixtures/`
3. **Visualize** — Ingest raw Crucible telemetry using shared notebooks in `analysis/notebooks/`
4. **Document** — Write findings as Markdown in the research goal folder

## Getting Started

### Prerequisites

- Python 3.10+
- Helm (for SUT deployment)
- kubectl configured for your cluster
- [Claude Code](https://claude.ai/code) (for autonomous research)

### Setup

```bash
pip install -r analysis/requirements.txt
```

### Deploying a Target (Doris)

```bash
helm install doris targets/doris/deploy/helm/doris -n crucible-research --create-namespace
```

### Running Notebooks

```bash
jupyter notebook analysis/notebooks/
```

## Current Targets

| Engine | Directory | Status |
|--------|-----------|--------|
| Apache Doris | `targets/doris/` | Active |
