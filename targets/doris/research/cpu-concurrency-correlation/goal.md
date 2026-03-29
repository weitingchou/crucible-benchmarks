---
allow_deploy_changes: true
auto_approve: true
---

# CPU Usage vs Query Concurrency Correlation

## Context
We are running Doris with a 3-FE / 3-BE cluster on Kubernetes, loaded with TPC-H SF1 data.
Before tuning any configuration, we need a baseline understanding of how CPU consumption
on the BE nodes scales as concurrent query load increases. This will inform future capacity
planning and help identify the concurrency level at which the cluster becomes CPU-bound.

## Engine
doris

## Hypothesis
BE CPU usage scales roughly linearly with query concurrency at low levels but saturates
at higher concurrency, causing query latency to degrade non-linearly once a CPU ceiling
is reached. We expect a clear inflection point where adding more concurrent queries stops
improving throughput and instead increases latency.

## Metrics of Interest
- BE CPU utilization (per-node and aggregate)
- Query throughput (queries per second)
- Query latency distribution (p75, p95, p99)
- FE CPU utilization (to confirm the bottleneck is on BE, not FE)

## Suggested Metrics
- be_cpu_usage_pct: `100 - avg(rate(doris_be_cpu{job="doris-be",device="cpu",mode="idle"}[1m]))`
- be_cpu_user: `avg(rate(doris_be_cpu{job="doris-be",device="cpu",mode="user"}[1m]))`
- be_cpu_system: `avg(rate(doris_be_cpu{job="doris-be",device="cpu",mode="system"}[1m]))`
- be_cpu_iowait: `avg(rate(doris_be_cpu{job="doris-be",device="cpu",mode="iowait"}[1m]))`
- cluster_qps: `doris_fe_qps{job="doris-fe"}`
- query_total: `rate(doris_fe_query_total{job="doris-fe"}[1m])`
- query_latency_p95: `doris_fe_query_latency_ms{job="doris-fe",quantile="0.95"}`
- query_latency_p99: `doris_fe_query_latency_ms{job="doris-fe",quantile="0.99"}`
- query_latency_p999: `doris_fe_query_latency_ms{job="doris-fe",quantile="0.999"}`
- be_active_queries: `doris_be_query_ctx_cnt{job="doris-be"}`
- be_scan_rows: `rate(doris_be_query_scan_rows{job="doris-be"}[1m])`
- be_load_average: `doris_be_load_average{job="doris-be"}`
- wg_cpu_time: `rate(doris_be_workload_group_cpu_time_sec{job="doris-be"}[1m])`

## Experiment Design
Run the full TPC-H SF1 workload at increasing concurrency levels: **1, 2, 4, 8, 16, 32**.
Each step should run for 5 minutes (`hold_for: 300s`) with no ramp-up, so each concurrency
level reaches steady state quickly. Use the existing `tpch-sf1-workload.sql` as the workload
for all runs.

Between runs, allow a 1-minute cool-down so CPU metrics from one step do not bleed into
the next.

## Constraints
- Use the existing TPC-H SF1 dataset — do not reload or alter data
- Each concurrency step must run long enough (>= 5 min) to reach steady state
- Keep the workload identical across all steps; only concurrency changes

## Success Criteria
- A clear chart or table showing CPU usage (BE and FE) at each concurrency level
- Identification of the concurrency level at which CPU saturates
- Quantified relationship: does CPU scale linearly, sub-linearly, or in steps?
- Latency degradation curve: at what concurrency does p99 latency begin to spike?
- Throughput plateau: at what concurrency does QPS stop increasing?
