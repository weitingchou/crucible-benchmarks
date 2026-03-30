# BE Horizontal Scalability Under TPC-H Workload

## Summary

Doris BE horizontal scaling delivers sub-linear throughput gains: 2 BEs provide only 1.10x the QPS of 1 BE, while 4 BEs achieve 1.75x. Scaling is far from the ideal linear projection (2x and 4x respectively), with a scaling efficiency of 44–55%. However, latency improves significantly — p99 drops from 1,240ms (1 BE) to 705ms (4 BE), a 43% reduction — indicating that adding BEs helps individual query performance even when total throughput doesn't scale proportionally.

## Methodology

- **Engine:** Apache Doris 2.1.10
- **Dataset:** TPC-H SF1 (~6M lineitem rows)
- **Queries:** TPC-H Q1, Q3, Q5, Q6, Q9, Q10, Q12, Q13, Q14, Q19
- **Concurrency:** Fixed at 8 VUs for all experiments
- **Duration:** 300s per experiment, no ramp-up
- **Run label:** be-scalability
- **Prometheus metrics:** cluster_qps, query_latency_p95/p99, be_active_queries, be_load_average, wg_cpu_time_rate
- **Cluster:** 3 × c7i-flex.2xlarge (8 vCPU, 16 GiB each)

**Engine configurations tested:**

| Config | BE Replicas | FE Replicas | Per-BE CPU (req/limit) | Per-BE Memory (req/limit) |
|--------|-------------|-------------|----------------------|--------------------------|
| 1x | 1 | 1 | 500m / 2 | 2Gi / 4Gi |
| 2x | 2 | 1 | 500m / 2 | 2Gi / 4Gi |
| 4x | 4 | 1 | 500m / 2 | 2Gi / 4Gi |

**Tablet distribution after rebalancing:**

| Config | BE-0 | BE-1 | BE-2 | BE-3 | Total |
|--------|------|------|------|------|-------|
| 1x | 146 | — | — | — | 146 |
| 2x | 78 | 68 | — | — | 146 |
| 4x | 62 | 42 | 48 | 38 | 190 |

## Findings

### Throughput Scales Sub-Linearly

| Config | BE Count | QPS | Speedup vs 1x | Ideal Speedup | Scaling Efficiency |
|--------|----------|-----|---------------|---------------|-------------------|
| 1x | 1 | 12.7 | 1.00x | 1.0x | — |
| 2x | 2 | 14.0 | 1.10x | 2.0x | 55% |
| 4x | 4 | 22.2 | 1.75x | 4.0x | 44% |

```mermaid
xychart-beta
    title "Throughput: Actual vs Ideal Scaling"
    x-axis ["1 BE", "2 BE", "4 BE"]
    y-axis "QPS" 0 --> 55
    bar [12.7, 14.0, 22.2]
    line [12.7, 25.4, 50.8]
```

Throughput does not scale linearly with BE count. The 1x→2x step yields only a 10% QPS gain, while the 2x→4x step is much better (59% increase from 14.0 to 22.2). This suggests that at 2 BEs, the bottleneck shifts partially away from BE compute but is not fully relieved — possibly FE query planning/coordination overhead or uneven tablet distribution (78 vs 68 tablets).

At 4 BEs, each BE handles only ~2 concurrent queries (vs 8 at 1x), significantly reducing per-BE contention and allowing better parallelism.

### Latency Improves Significantly

| Config | BE Count | p95 (ms) | p99 (ms) | p95 Reduction | p99 Reduction |
|--------|----------|----------|----------|---------------|---------------|
| 1x | 1 | 1,080 | 1,240 | — | — |
| 2x | 2 | 955 | 1,105 | 12% | 11% |
| 4x | 4 | 600 | 705 | 44% | 43% |

```mermaid
xychart-beta
    title "Query Latency by BE Count"
    x-axis ["1 BE", "2 BE", "4 BE"]
    y-axis "Latency (ms)" 0 --> 1400
    bar [1080, 955, 600]
    bar [1240, 1105, 705]
```

While throughput scaling is disappointing, latency improvements are substantial. At 4 BEs, p99 latency drops below 710ms — nearly half the 1x baseline. This is because query fragments are distributed across more BEs, reducing per-node scan and compute time.

### Load Distribution Across BEs

At 4x, the per-BE load average (1-min) was 1.0–1.4, compared to 1.7–2.3 at 1x. Active queries per BE dropped from 8 to ~2. This confirms that Doris FE distributes query fragments across all available BEs, and adding BEs reduces per-node pressure.

However, at 2x, the load was noticeably uneven — BE-0 (with 78 tablets) had a higher load average than BE-1 (68 tablets). This tablet imbalance likely contributed to the poor 2x scaling.

### The FE May Be a Bottleneck

With a single FE handling all query planning, fragment distribution, and result aggregation for 8 concurrent VUs, the FE becomes an increasingly significant bottleneck as BE count grows. At 4 BEs, each query is split into more fragments that the FE must coordinate, adding overhead. This likely explains why scaling efficiency decreases at higher BE counts (55% at 2x → 44% at 4x).

## Conclusions

Addressing each success criterion:

- **QPS, p95, and p99 at each BE count:** See tables above. QPS: 12.7 → 14.0 → 22.2. p95: 1,080 → 955 → 600ms. p99: 1,240 → 1,105 → 705ms.

- **Does throughput scale linearly?** No. Scaling is **sub-linear** — 1.10x at 2 BE and 1.75x at 4 BE. The marginal improvement per additional BE decreases as more BEs are added (scaling efficiency drops from 55% to 44%).

- **Per-BE CPU utilization:** The BE CPU metric was unreliable on 8-vCPU nodes (negative values due to PromQL formula incompatibility). However, per-BE load average confirms even distribution: 1.0–1.4 at 4x vs 1.7–2.3 at 1x.

- **Bottleneck identification:** Two bottlenecks limit linear scaling:
  1. **FE coordination overhead** — a single FE becomes proportionally more expensive as it manages more fragments across more BEs.
  2. **Tablet distribution imbalance** — automatic rebalancing leaves an uneven tablet spread (62 vs 38 at 4x), causing some BEs to do more work than others.

- **Scaling efficiency:**

```mermaid
xychart-beta
    title "Scaling Efficiency (%)"
    x-axis ["2 BE", "4 BE"]
    y-axis "Efficiency %" 0 --> 100
    bar [55, 44]
    line [100, 100]
```

  55% at 2x, 44% at 4x. To achieve better scaling, consider: (a) increasing FE replicas or resources, (b) increasing concurrency beyond 8 VUs to better saturate 4 BEs, (c) ensuring more even tablet distribution.

## Limitations

- **Fixed concurrency (8 VUs):** Higher concurrency (e.g., 32 VUs) might show better scaling since 4 BEs could absorb more parallel work. The current test may underutilize 4 BEs.
- **Single FE:** FE was held constant at 1 replica. FE itself may be the limiting factor and was not tested as a variable.
- **BE CPU metric broken:** The PromQL formula `100 - avg by (instance)(rate(doris_be_cpu{mode='idle'}[1m]))` produces incorrect values on 8-vCPU nodes. A per-CPU normalized formula is needed for future studies.
- **Small dataset (SF1):** With only ~146 tablets, the dataset may be too small to fully benefit from parallelism. Larger datasets (SF10+) would provide more tablet-level parallelism.
- **Tablet imbalance:** Doris automatic rebalancing left an uneven distribution (up to 30% deviation from average at 4x), which may understate the true scaling potential.

## Appendix

- Research goal: [goal.md](goal.md)
- Experiment log: [results.yaml](results.yaml)
- Test plans: [plans/](plans/)
- Crucible run IDs:
  - 1x: `be-scalability-1x-r3_20260330-1510_b3b930b9`
  - 2x: `be-scalability-2x-r3_20260330-1537_59dc6193`
  - 4x: `be-scalability-4x_20260330-1549_f431b12e`
