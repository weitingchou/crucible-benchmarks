# Project Overview: Crucible Research (`crucible-research`)
This repository is the central hub for performance analysis, system evaluation, and benchmarking of the target databases tested by the Crucible platform.

While this repository contains the necessary deployment scripts to spin up the Systems Under Test (SUT), its primary purpose is to host the analytical tools, Jupyter notebooks, and goal-driven autonomous research investigations that document how these systems behave under severe load.

1. Repository Structure
The repository enforces a strict separation between shared analytical tools and engine-specific evaluations.

```
.
├── analysis/                   # Shared analytical engines and visualizers
│   ├── requirements.txt        # Python dependencies (pandas, matplotlib, jupyter, etc.)
│   ├── parsers/                # Scripts to parse Crucible's raw k6 CSVs or Prometheus metrics
│   └── notebooks/              # Shared Jupyter notebooks for cross-engine visualization
├── infra/                      # Shared infrastructure deployments
│   └── helm/prometheus/        # Prometheus for SUT metrics collection
├── targets/                    # Isolated folders for each System Under Test (SUT)
│   └── doris/
│       ├── deploy/             # Helm charts/IaC for reproducible environments
│       ├── fixtures/           # Data generation configs, DDLs, workload SQL
│       └── research/           # Goal-driven research investigations
│           └── {goal}/
│               ├── goal.md     # Human-authored hypothesis and experiment design
│               ├── plans/      # Auto-generated Crucible test plan YAMLs
│               ├── results.yaml# Structured log of every experiment run
│               └── report.md   # Auto-generated findings report
├── .claude/skills/research/    # The /research skill definition
├── CLAUDE.md
├── DESIGN_CONTEXT.md           # This architecture document
└── README.md
```

2. The Analytical Workflow
The core lifecycle of this repository follows a scientific method approach to systems testing:
  1. Deploy & Execute (Reproducibility): Use the configurations in `deploy/` and `fixtures/` to create a standardized baseline and hammer the target engine with Crucible.
  2. Research (Autonomous): Define a hypothesis in `research/{goal}/goal.md`, invoke `/research`, and let Claude autonomously plan experiments, submit test runs via Crucible, collect results, and produce a findings report.
  3. Visualize & Explore (Discovery): Use the shared Jupyter notebooks in `/analysis/notebooks/` to ingest the raw Crucible telemetry (from S3 or Prometheus). Explore the data to find saturation points, query latencies, CPU bottlenecks, and memory leaks.
  4. Document & Conclude (Reporting): Review the auto-generated `report.md` in the research goal folder. Provide feedback to iterate on gaps.

3. Target Isolation (`/targets/{engine_name}/`)
Each SUT is fully self-contained to ensure that research findings and their corresponding test parameters are tightly coupled.

  3.1 Research Investigations (`research/`)
    - The core deliverable of this repository.
    - Each investigation is self-contained in its own folder with goal, plans, results, and report together.
    - Reports are generated automatically by the /research skill, backed by data from Crucible test runs.
    - Test plans (Crucible YAML definitions) live inside each research goal's `plans/` subfolder, co-located with the investigation that produced them.

  3.2 Deployment & Configuration (`deploy/` & `fixtures/`)
    - Helm (1st Priority): Helm charts to ensure the SUT is provisioned exactly the same way every time.
    - Fixtures: Scripts, DDLs, and workload SQL to generate the datasets and queries required for testing.

4. Shared Analysis (`/analysis/`)
Because Crucible normalizes execution telemetry across all targets, the analytical tooling is engine-agnostic.
- Parsers: Python scripts to download the raw `k6_raw.csv` artifacts from the `project-crucible-storage` S3 bucket.
- Notebooks: Jupyter notebooks containing reusable statistical models to calculate percentiles (p90, p95, p99), throughput (TPS), and error rates, allowing for apples-to-apples comparisons across completely different data engines.
