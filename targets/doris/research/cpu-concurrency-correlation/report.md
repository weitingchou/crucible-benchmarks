# CPU Usage vs Query Concurrency Correlation

## Summary

BE CPU usage scales linearly with concurrency from 1 to 2 VUs (46% → 89%), then saturates at ~99% by 4 VUs on this 2-CPU node. Once CPU is saturated, additional concurrency provides zero throughput gain — QPS plateaus at ~13 queries/sec — while query latency degrades linearly with each doubling of concurrency. At 32 VUs the BE node crashes from resource exhaustion, establishing a hard stability ceiling.

## Methodology

- **Engine:** Apache Doris 2.x, 1 FE + 1 BE on Kubernetes (2 CPU, ~2 GB memory per BE)
- **Dataset:** TPC-H SF1 (~6M lineitem rows, 8 tables)
- **Queries:** Full TPC-H suite Q1–Q22, executed in round-robin by k6
- **Parameters varied:** k6 concurrency (VUs): 1, 2, 4, 8, 16, 32
- **Duration per experiment:** 300s (5 minutes), no ramp-up
- **Execution:** Sequential (one concurrency level at a time) to isolate metrics
- **Run label:** cpu-concurrency-correlation
- **Prometheus metrics collected:** be_cpu_usage_pct, be_cpu_user, be_cpu_system, cluster_qps, query_latency_p95, query_latency_p99, be_active_queries, be_load_average, wg_cpu_time_rate

## Findings

### CPU Saturates at 4 Concurrent VUs

CPU usage scales roughly linearly from c=1 to c=2 (46% → 89%), then hits the ceiling at c=4 (99.4%). Beyond c=4, CPU remains pegged at ~100% regardless of concurrency.

| Concurrency | BE CPU % | CPU User | CPU System |
|-------------|----------|----------|------------|
| 1           | 46       | 133      | 10         |
| 2           | 89       | 175      | 13         |
| 4           | 99.4     | 186      | 13         |
| 8           | 100      | 186      | 13.5       |
| 16          | 100      | 185      | 15         |
| 32          | CRASHED  | —        | —          |

The CPU user-mode time plateaus around 185–186 once saturated, indicating the BE has no idle cycles left. System-mode CPU stays relatively constant at 13–15%, suggesting kernel overhead doesn't scale significantly with query concurrency.

### Throughput Peaks at c=2 and Plateaus

QPS increases modestly from c=1 to c=2 (+22%), then remains flat or slightly declines at higher concurrency. The cluster cannot process more queries per second once CPU is saturated — additional VUs just queue behind the same CPU bottleneck.

| Concurrency | QPS   | QPS Change |
|-------------|-------|------------|
| 1           | 11.2  | baseline   |
| 2           | 13.7  | +22%       |
| 4           | 13.3  | −3%        |
| 8           | 13.3  | 0%         |
| 16          | 12.5  | −6%        |
| 32          | CRASHED | —        |

The slight QPS decline at c=16 likely reflects increased context-switching overhead and memory pressure from managing 16 concurrent query execution contexts.

### Latency Degrades Linearly Beyond Saturation

Once CPU saturates (c≥4), latency grows almost linearly with each doubling of concurrency. This is classic queuing behavior: with fixed throughput, doubling the number of in-flight requests roughly doubles wait time.

| Concurrency | p95 (ms) | p99 (ms) | p95 vs c=1 | p99 vs c=1 |
|-------------|----------|----------|------------|------------|
| 1           | 230      | 327      | 1.0×       | 1.0×       |
| 2           | 370      | 650      | 1.6×       | 2.0×       |
| 4           | 690      | 950      | 3.0×       | 2.9×       |
| 8           | 1,120    | 1,420    | 4.9×       | 4.3×       |
| 16          | 2,120    | 2,660    | 9.2×       | 8.1×       |
| 32          | CRASHED  | —        | —          | —          |

The inflection point where latency begins to spike is at **c=4** — the same point where CPU reaches saturation. Before this (c=1 and c=2), latency increases are moderate because the CPU still has headroom to absorb additional work.

### BE Node Crashes at c=32

Both in the initial concurrent batch (63 total VUs) and the isolated c=32 sequential run, the BE node was killed by Kubernetes (likely OOM). 32 concurrent TPC-H queries on a 2-CPU / ~2GB node exceeds not just CPU capacity but memory capacity, as each query execution context consumes memory for intermediate results, hash tables, and scan buffers.

### Load Average Correlates with Concurrency

The 1-minute load average scales predictably with concurrency, providing a useful secondary indicator:

| Concurrency | Load Avg (1-min) |
|-------------|------------------|
| 1           | 3.8              |
| 2           | 4.6              |
| 4           | 6.0              |
| 8           | 8.0              |
| 16          | 10.0             |

## Conclusions

Addressing each success criterion from the goal:

- **CPU usage table at each concurrency level:** Provided above. CPU scales linearly from c=1 (46%) to c=2 (89%), saturates at c=4 (99.4%), and remains pegged at 100% through c=16.

- **Concurrency level at which CPU saturates:** **c=4** (4 concurrent VUs on a 2-CPU BE node). Even c=2 is already at 89%.

- **Quantified relationship:** CPU scales **linearly** with concurrency below saturation (roughly 45% per VU). Above saturation, CPU is flat at 100% — the relationship becomes a step function.

- **Latency degradation curve:** p99 latency begins to spike at **c=4** (950ms, nearly 3× the c=1 baseline of 327ms). By c=16, p99 reaches 2,660ms (8.1× baseline). The degradation is approximately linear with concurrency once CPU is saturated.

- **Throughput plateau:** QPS stops increasing at **c=2** (13.7 QPS). From c=4 onward, QPS is flat at ~13 and begins declining slightly at c=16 (12.5 QPS). The maximum sustainable throughput on this configuration is approximately **13–14 queries/sec**.

## Limitations

- **Single BE node:** This study used 1 BE with 2 CPUs. A multi-BE cluster would distribute query fragments across nodes, potentially shifting the saturation point.
- **k6 metrics unavailable:** The k6 driver returned empty metrics for all runs. All latency and QPS data comes from Doris FE Prometheus metrics (aggregated across the FE's observation window), not per-query k6 measurements.
- **No memory metrics:** The study focused on CPU. Memory pressure likely contributed to the c=32 crash but was not directly measured.
- **TPC-H workload bias:** TPC-H queries are CPU-heavy analytical queries. An OLTP or mixed workload would likely show different saturation characteristics.
- **No I/O analysis:** I/O wait was negligible (<0.05%) at all concurrency levels for this dataset size, but larger datasets may introduce I/O as a bottleneck before CPU.

## Appendix

- Research goal: [goal.md](goal.md)
- Experiment log: [results.yaml](results.yaml)
- Test plans: [plans/](plans/)
- Crucible run IDs:
  - c=1: `cpu-concurrency-c1-seq_20260329-1012_a0e0b0fd`
  - c=2: `cpu-concurrency-c2-seq_20260329-1018_5839f20c`
  - c=4: `cpu-concurrency-c4-seq_20260329-1024_3193d924`
  - c=8: `cpu-concurrency-c8-seq_20260329-1030_8278bc7d`
  - c=16: `cpu-concurrency-c16-seq_20260329-1036_9f6c4011`
  - c=32: `cpu-concurrency-c32-seq_20260329-1042_7f4e0913` (FAILED — BE crash)
