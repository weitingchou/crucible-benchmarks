# Crucible Benchmarks

Performance analysis, system evaluation, and benchmarking of databases tested by the [Crucible](https://github.com/your-org/crucible) platform.

This repository hosts analytical tools, Jupyter notebooks, deployment scripts for Systems Under Test (SUTs), and Markdown insight reports documenting how these systems behave under severe load.

## Repository Structure

```
.
├── analysis/                   # Shared, engine-agnostic analytical tooling
│   ├── requirements.txt        # Python dependencies (pandas, matplotlib, jupyter, etc.)
│   ├── parsers/                # Scripts to parse raw k6 CSVs and Prometheus metrics
│   └── notebooks/              # Reusable Jupyter notebooks for cross-engine visualization
├── targets/                    # Isolated folders per System Under Test (SUT)
│   └── doris/
│       ├── reports/            # Markdown insight documents (core deliverable)
│       ├── deploy/             # Helm charts / IaC for reproducible environments
│       ├── fixtures/           # Data generation configs and DDLs
│       └── test_plans/         # Crucible YAML test plan definitions
├── CLAUDE.md
├── DESIGN_CONTEXT.md
└── README.md
```

## Workflow

1. **Deploy & Execute** — Provision SUTs via Helm charts in `targets/{engine}/deploy/`, generate datasets with `fixtures/`, and run Crucible load tests defined in `test_plans/`.
2. **Visualize & Explore** — Ingest raw Crucible telemetry (k6 CSVs from S3, Prometheus metrics) using shared notebooks in `analysis/notebooks/`. Identify saturation points, query latencies, CPU bottlenecks, and memory leaks.
3. **Document & Conclude** — Formalize findings as Markdown reports in `targets/{engine}/reports/` (e.g., `2026-03-doris-join-spill-analysis.md`), linking back to the specific test plan that generated the load.

## Getting Started

### Prerequisites

- Python 3.10+
- Helm (for SUT deployment)

### Setup

```bash
pip install -r analysis/requirements.txt
```

### Running Notebooks

```bash
jupyter notebook analysis/notebooks/
```

## Current Targets

| Engine | Directory |
|--------|-----------|
| Apache Doris | `targets/doris/` |
