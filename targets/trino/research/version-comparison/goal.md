---
allow_deploy_changes: true
auto_approve: true
---

# Trino Query Performance: v465 vs v480 on Iceberg/S3

## Context
We are adopting Trino as an OLAP query engine for Iceberg tables stored on S3.
Before upgrading from Trino 465 (our current production version) to the latest
release (480), we need to quantify any performance regression or improvement on
our core analytical workload. Trino 480 includes several optimizer improvements,
fault-tolerant execution enhancements, and Iceberg connector updates that may
affect query planning and execution performance.

The test infrastructure runs on EKS (3 × c7i-flex.2xlarge nodes). Trino will be
deployed via Helm with a coordinator + 2 workers configuration. Both versions
will query the same Iceberg dataset on S3, eliminating data format differences
as a variable.

## Engine
trino

## Hypothesis
Trino 480 delivers measurably better query performance than 465 on TPC-H
analytical queries over Iceberg/S3, due to accumulated optimizer improvements
and Iceberg connector enhancements across 15 minor releases. We expect 10–20%
improvement in throughput and tail latency for scan-heavy and join-heavy queries,
with possible regressions on specific query patterns due to planner changes.

## Metrics of Interest
- Query throughput (QPS) per version
- Query latency distribution (p50, p95, p99) per version
- Per-query latency comparison (which specific TPC-H queries improved or regressed)
- Coordinator CPU utilization (planning overhead)
- Worker CPU utilization (execution overhead)
- JVM heap usage and GC pressure per version

## Suggested Metrics
- trino_cpu: `rate(process_cpu_seconds_total{job="trino"}[1m])`
- trino_heap_used: `jvm_memory_bytes_used{job="trino",area="heap"}`
- trino_gc_time: `rate(jvm_gc_collection_seconds_sum{job="trino"}[1m])`
- trino_active_queries: `trino_QueryManager_RunningQueries{job="trino"}`

## Data Generation Strategy

### Approach: Use Trino's built-in `tpch` connector

Trino ships with a `tpch` catalog that generates TPC-H data on-the-fly in memory.
We use `CREATE TABLE ... AS SELECT` (CTAS) to materialize TPC-H tables into
Iceberg format on S3. This is the most efficient approach because:
- No external data generation tools or file conversion needed
- Trino writes native Parquet files with Iceberg metadata directly to S3
- Parallel writers across Trino workers maximize throughput
- The same Iceberg tables can be queried by both Trino versions

### Catalog: JDBC catalog backed by a small PostgreSQL

The lightest catalog option that avoids AWS managed services. Trino's Iceberg
connector supports `iceberg.catalog.type=jdbc` natively — just point it at a
PostgreSQL instance. We deploy a tiny PostgreSQL pod (~100m CPU, 256Mi memory)
alongside Trino in the same namespace. No Hive Metastore, no AWS Glue, no
external dependencies beyond S3.

```
Trino (coord + workers) → JDBC Catalog (tiny PostgreSQL) → S3 (Parquet data)
```

### Steps
1. Deploy a small PostgreSQL pod for the Iceberg JDBC catalog
2. Deploy Trino v465 with `tpch` and `iceberg` connectors configured:
   - `iceberg.catalog.type=jdbc`
   - `iceberg.jdbc-catalog.connection-url=jdbc:postgresql://<pg-host>:5432/iceberg`
   - `iceberg.jdbc-catalog.catalog-name=iceberg`
   - S3 warehouse path: `s3://claude-bot-workspace-project-crucible-storage/research/targets/trino/`
3. Create the TPC-H schema: `CREATE SCHEMA iceberg.tpch`
4. Generate data via CTAS for each table:
   ```sql
   CREATE TABLE iceberg.tpch.lineitem
   WITH (format = 'PARQUET')
   AS SELECT * FROM tpch.sf10.lineitem;
   ```
5. Repeat for all 8 TPC-H tables
6. Verify row counts match expected SF10 values
7. Run `ANALYZE` on all tables to collect statistics

### Scale Factor: SF10
- ~60M lineitem rows (~4–5 GB Parquet)
- ~15M orders, ~1.5M customer, ~8M partsupp
- ~6–7 GB total on S3
- Large enough to stress distributed execution and S3 I/O across workers
- Can start here and scale to SF100 (~60 GB) if the results are inconclusive

### S3 Layout
```
s3://claude-bot-workspace-project-crucible-storage/
  research/targets/trino/
    iceberg/
      tpch/
        lineitem/
        orders/
        customer/
        ...
```

## Experiment Design
Deploy each Trino version sequentially with identical cluster configuration.
Run the same TPC-H workload against the shared Iceberg dataset.

### Cluster Configuration (identical for both versions)
- 1 Coordinator (2 CPU, 4Gi memory)
- 2 Workers (2 CPU, 4Gi memory each)
- Iceberg connector with JDBC catalog (PostgreSQL)
- S3 storage at the bucket path above

### Test Matrix

| Run | Trino Version | Workload | Concurrency | Duration |
|-----|---------------|----------|-------------|----------|
| 1   | 465           | TPC-H Q1–Q22 on Iceberg SF10 | 4 VUs | 300s |
| 2   | 480           | TPC-H Q1–Q22 on Iceberg SF10 | 4 VUs | 300s |

### Version Switch Process
1. Run experiments on v465
2. `helm upgrade` to change the Trino image tag to v480
3. Wait for all pods to restart and pass health checks
4. Verify the Iceberg tables are accessible (run a count query)
5. Run experiments on v480

Note: Trino is a stateless query engine — no data rebalancing is needed between
version switches. The JDBC catalog (PostgreSQL) and Iceberg data (S3) persist
across Trino restarts. Both versions query the exact same tables.

## Constraints
- Use identical cluster resources for both versions (same CPU, memory, worker count)
- Use the same Iceberg dataset for both versions — generate once, query twice
- Do not modify Iceberg table properties between versions
- Do not use AWS managed services (except S3) — use JDBC catalog with PostgreSQL
- Each version must run long enough (>= 5 min) to reach steady state
- Use 4 VUs concurrency (moderate load to avoid overwhelming 2 workers)
- Keep the catalog PostgreSQL running across both tests (it holds table metadata)

## Success Criteria
- Side-by-side comparison table: QPS, p50, p95, p99 for v465 vs v480
- Per-query breakdown: which TPC-H queries improved, regressed, or stayed the same
- Quantified overall speedup or regression (% change in QPS and latency)
- Resource efficiency comparison: CPU utilization and GC overhead per version
- Clear recommendation: is v480 a safe upgrade from a performance perspective?
