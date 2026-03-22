# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository is the central hub for performance analysis and benchmarking of databases tested by the Crucible platform. It hosts analytical tools, Jupyter notebooks, deployment scripts for Systems Under Test (SUTs), and Markdown insight reports documenting system behavior under severe load.

## Architecture

The repo enforces strict separation between shared analytical tools and engine-specific evaluations:

- **`analysis/`** — Engine-agnostic shared tooling
  - `parsers/` — Python scripts to parse raw k6 CSVs and Prometheus metrics from the `project-crucible-storage` S3 bucket
  - `notebooks/` — Reusable Jupyter notebooks for cross-engine visualization (percentiles, TPS, error rates)
  - `requirements.txt` — Python dependencies (pandas, matplotlib, jupyter, etc.)

- **`targets/{engine}/`** — Fully self-contained per-SUT directories (e.g., `doris/`, `trino/`)
  - `reports/` — Markdown insight documents (the core deliverable), linked to specific test plans with exported charts
  - `deploy/` — Helm charts for reproducible SUT provisioning
  - `fixtures/` — Data generation configs and DDLs for test datasets
  - `test_plans/` — Crucible YAML test plan definitions (concurrency, workload SQL, scaling modes)

## Deploying Doris

```bash
# Install (from repo root)
helm install doris targets/doris/deploy/helm/doris -n doris --create-namespace

# Override replicas or resources for a lighter dev cluster
helm install doris targets/doris/deploy/helm/doris -n doris --create-namespace \
  --set fe.replicaCount=1 --set be.replicaCount=1

# Upgrade after values change
helm upgrade doris targets/doris/deploy/helm/doris -n doris

# Uninstall (PVCs are not deleted automatically)
helm uninstall doris -n doris
```

The chart deploys:
- **FE StatefulSet** — 3 replicas (1 leader + 2 followers), MySQL-compatible query on port `9030`, HTTP UI on `8030`
- **BE StatefulSet** — 3 replicas, registers with FE automatically via `FE_SERVERS` env var
- Headless services for stable DNS within each StatefulSet, plus a client-facing FE service

## Workflow

1. **Deploy & Execute** — Provision SUTs via Helm charts in `targets/{engine}/deploy/`, run Crucible load tests defined in `test_plans/`
2. **Visualize & Explore** — Ingest raw Crucible telemetry using shared notebooks in `analysis/notebooks/`
3. **Document & Conclude** — Formalize findings as Markdown reports in `targets/{engine}/reports/` (e.g., `2026-03-doris-join-spill-analysis.md`)

## Key Design Decisions

- Target isolation: each SUT's reports, deploy configs, fixtures, and test plans are co-located so findings stay coupled to their test parameters
- Analysis tooling is engine-agnostic because Crucible normalizes telemetry across all targets
- Helm is the first-priority deployment mechanism for reproducibility
