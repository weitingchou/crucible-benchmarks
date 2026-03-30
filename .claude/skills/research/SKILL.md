---
name: research
description: |
  Run autonomous database performance research from a goal file.
  Use when the user invokes /research with a path to a goal.md under
  targets/{engine}/research/{goal}/. Executes the full loop: read goal,
  plan experiments, submit test runs via Crucible MCP, collect results,
  analyze, iterate, and produce a final report.
argument-hint: targets/{engine}/research/{goal}/goal.md
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent
effort: high
---

# Autonomous Research Protocol

You are conducting a database performance research investigation defined
by the goal file at `$ARGUMENTS`. Follow this protocol precisely.

---

## Crucible Test Model

Understand how Crucible structures test execution before planning experiments:

- A **test plan** = **test environment** + **test workload**.
- The **test environment** is the SUT deployed by this project (Helm charts,
  resource limits, configs). It is described in the test plan YAML under
  `test_environment`.
- The **test workload** (SQL queries, concurrency, duration) must be **uploaded
  to Crucible** via `mcp__crucible__upload_workload_sql`, then referenced in
  the test plan YAML under `execution.workload`.
- A test plan is uploaded once. You can then **submit multiple test runs**
  against the same plan. All runs inherit the plan's `run_label`.

### When to create multiple test plans vs. multiple runs

| What varies between experiments | Action |
|---|---|
| **Workload** (different queries, concurrency, duration) | Create a **new test plan** with its own workload upload |
| **Engine spec** (memory, replicas, config flags) | Reuse the **same test plan**, submit a **new run** with different spec info at submission time |
| **Both** | Create multiple test plans (one per workload) × submit multiple runs per plan (one per spec) |

The spec info (resource limits, config changes, etc.) is provided when triggering
a test run via `mcp__crucible__submit_test_run`, so you do not need to re-upload
the plan just because the engine configuration changed.

### Observability in test plans

Crucible can collect Prometheus metrics from the target engine during the test run
automatically. You do **not** need to query Prometheus yourself. Instead, define an
`observability` block in the test plan YAML:

```yaml
test_environment:
  # ... connection details ...
  observability:
    prometheus_sources:
      - name: engine
        url: "http://<prometheus-service>.<namespace>.svc.cluster.local:9090"
        metrics:
          - name: "<metric_label>"
            query: "<PromQL expression>"
        resolution: 15        # optional, seconds between samples (default: 15)
        max_data_points: 500   # optional (default: 500)
```

When the test run completes, the result JSON returned by the Crucible MCP contains
both k6 load test results and the collected Prometheus metrics.

**Choosing metrics:** Based on the research goal's hypothesis and metrics of
interest, select PromQL queries that will provide insight. If the goal file
includes a `suggested_metrics` section, use those as a starting point. Otherwise,
determine the right metrics by reading the engine documentation and understanding
what internal counters are relevant to the hypothesis. For example:

- Query performance → query latency histograms, QPS counters
- Memory pressure → memory usage, cache hit rates, spill counters
- I/O behavior → disk read/write throughput, compaction stats
- Concurrency → thread pool utilization, connection counts

---

## Phase 1: Understand

1. **Read the goal file** (`$ARGUMENTS`) in full.
2. **Identify the key elements:**
   - `Engine` — which target database (determines deploy config, fixtures, connection details)
   - `Context` — background that motivates the investigation
   - `Hypothesis` — the specific claim to prove or disprove
   - `Metrics of Interest` — what to measure (latency, throughput, memory, etc.)
   - `Suggested Metrics` — optional PromQL queries the author recommends; use
     these as a starting point but add others if needed for the hypothesis
   - `Experiment Design` — the human's suggested approach (follow it unless clearly flawed)
   - `Constraints` — hard boundaries on what you may and may not do
   - `Success Criteria` — what the final report must answer
   - `allow_deploy_changes` — whether you are permitted to modify the SUT deployment
     (Helm values, resource limits, replica counts). Defaults to `false` if absent.
3. **Check for a `## Feedback` section.** If present, this is a follow-up iteration:
   - Read the existing `results.yaml` and `report.md` in the same folder.
   - Understand what was already tested and what gaps the feedback identifies.
   - Plan only the follow-up experiments needed to address the feedback.
4. **Read the engine's deploy config and fixtures** to understand the current SUT
   state (version, resource limits, loaded datasets, connection details).
5. **Study the engine's data distribution model** (relevant when experiments
   involve scaling nodes in or out):
   - How does the engine partition and distribute data across nodes?
     (e.g., hash-partitioned tablets, consistent hashing, replicated shards)
   - Does the engine automatically rebalance data when nodes are added or removed?
     If so, what triggers it, how long does it take, and how can you monitor progress?
   - Are there manual commands to trigger or verify rebalancing?
   - What does "balanced" look like? (e.g., equal partition counts, even data size)
   - Record these findings — you will need them in the deployment change protocol
     (§3a-1 Step 6) to ensure data is evenly distributed before running experiments.
6. **Determine the Prometheus metrics** to include in test plans:
   - Start with any `suggested_metrics` from the goal file.
   - Add metrics that are relevant to the hypothesis based on engine knowledge.
   - Read engine documentation or existing deploy configs to find available
     metric names and label conventions.
   - Locate the Prometheus service URL from the infra deployment
     (e.g., `infra/helm/prometheus/values.yaml`).

---

## Phase 2: Plan

1. **Design a set of experiments** that systematically address the hypothesis.
   Each experiment should vary one parameter at a time unless the goal explicitly
   calls for combinatorial testing.
2. **Identify the experiment axes:**
   - **Workload axis** — which queries, concurrency levels, and durations to test.
     Each distinct workload requires its own test plan YAML and workload upload.
   - **Spec axis** — which engine configurations to test (memory, replicas, flags).
     These are passed at run submission time and reuse the same uploaded plan.
   - Map out the full matrix: `workloads × specs = total runs`.
3. **If experiments involve scaling nodes in or out**, plan how to verify
   data rebalancing based on the findings from Phase 1 Step 5:
   - Identify the specific command or query to check rebalancing progress
     (e.g., comparing per-node partition counts, querying a system balance
     table, calling a rebalance status API).
   - Identify the specific command or query to confirm completion (what does
     "done" look like — equal partition counts? a status field changing?).
   - Document both in the experiment plan so they are ready for use in
     §3a-1 Step 6 during execution.
4. **For each experiment, define:**
   - A short description (what it tests and why)
   - Which test plan it uses (new or existing)
   - Which spec overrides to pass at submission (if any)
   - Which Prometheus metrics to collect (included in the plan's observability block)
   - What outcome would confirm or reject the hypothesis
4. **Write the experiment plan as a summary** to the user before executing.
   Wait for approval unless the goal file contains `auto_approve: true`.

---

## Phase 3: Execute

### 3a. Prepare workloads and plans

- For each distinct workload in the experiment plan:
  1. Upload the workload SQL via `mcp__crucible__upload_workload_sql`.
  2. Create a test plan YAML in the `plans/` subfolder of the research goal
     directory. Name it descriptively (e.g., `q9-q21-c4.yaml`).
  3. Set `run_label` to the goal folder name (e.g., `join-spill-analysis`).
  4. Include the `observability.prometheus_sources` block with the metrics
     determined in Phase 1.
  5. Validate via `mcp__crucible__validate_test_plan`.

### 3a-1. Deployment change protocol

When experiments require SUT configuration changes (replica counts, resource
limits, Doris config flags, etc.), follow this protocol. **Skip this section
entirely if no deployment changes are needed.**

#### Prerequisites

- Verify `allow_deploy_changes: true` in the goal file. If absent or false,
  stop and ask the user to update the goal file.

#### Step 1: Record the baseline

Before making any changes, capture the current Helm values so you can restore
them later:

```bash
helm get values doris -n crucible-research -o yaml > /tmp/doris-baseline-values.yaml
```

Store the baseline path. You will need it in the restore step.

#### Step 2: Check cluster capacity

Before scaling out (adding replicas or increasing resource limits), verify the
cluster can accommodate the new pods:

```bash
# Check available resources on each node
kubectl describe nodes | grep -A 6 "Allocated resources"

# Check current pod placement
kubectl get pods -n crucible-research -o wide
```

Evaluate whether the target configuration fits. Consider:
- **CPU requests** — will the new pods' requests fit on existing nodes?
- **Memory requests** — same check; memory is often the tighter constraint.
- **Node count** — if no single node can fit a new pod, the scheduler will fail.

If the cluster lacks capacity, **inform the user** with the specific shortfall
(e.g., "need 2Gi memory but the most available node has 1.5Gi free") and ask
how to proceed. Do not blindly apply changes that will leave pods in Pending.

#### Step 3: Apply the change

```bash
helm upgrade doris targets/{engine}/deploy/helm/doris -n crucible-research \
  --set be.replicaCount=3 \
  --set be.resources.limits.cpu=4 \
  # ... other overrides
```

#### Step 4: Wait for rollout

Wait for all pods to be Running and Ready:

```bash
kubectl rollout status statefulset/doris-doris-be -n crucible-research --timeout=300s
kubectl rollout status statefulset/doris-doris-fe -n crucible-research --timeout=300s
```

#### Step 5: Verify engine health

Pod readiness alone is not enough — the engine must be internally consistent.
Run engine-specific health checks:

- **Doris:** `SHOW BACKENDS\G` — all backends must show `Alive: true`.
  If a new backend is not yet registered, wait up to 60 seconds and recheck.
  Also run a simple query (e.g., `SELECT COUNT(*) FROM tpch.lineitem`) to
  confirm the data is accessible.
- **Other engines:** adapt the health check to the engine (e.g., Trino
  `SELECT * FROM system.runtime.nodes`).

Only proceed after the health check passes.

#### Step 6: Wait for data rebalancing

After scaling out (adding nodes/replicas), many distributed databases
automatically redistribute data across the new topology. Running experiments
before rebalancing completes will produce skewed results — some nodes will be
hot (serving all data) while others sit idle.

**Skip this step** if the engine has no local data distribution (e.g., stateless
query engines that read from external storage), as determined in Phase 1 Step 5.

1. **Trigger or confirm rebalancing** using the mechanism identified in
   Phase 1 Step 5. Common patterns:
   - **Automatic migration** — the engine detects imbalance and migrates
     partitions in the background. Just wait.
   - **Manual rebalance command** — some engines require an explicit trigger.
   - **No automatic rebalancing** — data stays on original nodes; you may
     need to reload data or run a compaction/repair cycle.

2. **Monitor rebalancing to completion.** Use the progress-checking method
   identified in Phase 2 (see below). Do NOT use a fixed timer — poll until
   the engine reports that rebalancing is done. Rebalancing may take seconds
   for small datasets or hours for large ones.

3. **Verify balanced distribution.** After rebalancing reports completion,
   confirm that no node has more than ~20% deviation from the average
   partition count.

4. **After scaling in** (removing replicas), verify the engine has migrated
   data off the removed nodes and no partitions are under-replicated.

5. **Log the final distribution** in results.yaml under the experiment's
   `notes` field (e.g., "tablets: BE-0=28, BE-1=29, BE-2=29").

Only proceed to submit test runs after rebalancing is verified complete.

#### Step 7: Cool-down between spec changes

When switching between deployment configurations (e.g., after testing 3 BE,
scaling back to 1 BE for the next experiment):
1. Apply the new Helm values (repeat steps 3–6).
2. Wait **60 seconds** after rebalancing completes before submitting the
   next test run. This allows Prometheus rate() windows to flush stale data
   from the previous configuration.

#### Step 8: Restore after investigation

After all experiments complete (or if the investigation is aborted), restore
the original deployment:

```bash
helm upgrade doris targets/{engine}/deploy/helm/doris -n crucible-research \
  -f /tmp/doris-baseline-values.yaml
```

Then repeat steps 4–5 (wait for rollout + health check) to confirm the
cluster is back to its original state.

### 3b. Submit runs

- For each experiment (plan × spec combination):
  1. If the experiment requires deployment changes, follow the deployment
     change protocol (§3a-1) before submitting.
  2. Submit the test run via `mcp__crucible__submit_test_run`, passing any
     spec overrides. Record the `run_id` immediately.

### 3c. Monitor

- After submitting runs, enter a **monitoring loop** that polls
  `mcp__crucible__monitor_test_progress` for every active run.
- **Display a status table** to the user on each poll cycle showing all runs
  and their current state:

  ```
  | Run (plan_name)        | Concurrency | Status     | Elapsed |
  |------------------------|-------------|------------|---------|
  | cpu-concurrency-c1-seq | 1           | COMPLETED  | 5m 01s  |
  | cpu-concurrency-c2-seq | 2           | EXECUTING  | 3m 22s  |
  | cpu-concurrency-c4-seq | 4           | PENDING    | —       |
  ```

- **Poll interval:** every **3 minutes**. Do not poll more frequently.
- On each poll cycle, check for newly completed or failed runs and trigger
  result collection immediately (see §3d).
- Continue the monitoring loop until every run has reached a terminal state
  (`COMPLETED` or `FAILED`).

### 3d. Collect

- **Collect results eagerly:** as soon as a run reaches `COMPLETED`, fetch its
  results via `mcp__crucible__get_test_results` in the same poll cycle. Do NOT
  wait for all runs to finish before collecting — fetch each result the moment
  it becomes available. This ensures:
  - Partial progress is preserved if later runs fail.
  - Data is available for early analysis while other runs are still executing.
- The response JSON contains both **k6 load test metrics** (latency percentiles,
  TPS, error rates) and **Prometheus metrics** (as defined in the plan's
  observability block).
- Extract the metrics of interest from the response.
- Log the results to `results.yaml` immediately after extraction (see §3e) —
  do not batch logging.

### 3d-1. Handle failures

- If a run reaches `FAILED`:
  1. **Log the failure** in results.yaml with the error detail.
  2. **Check SUT health** — query the engine (e.g., `SHOW BACKENDS` for Doris,
     pod status via `kubectl`) to determine if the SUT crashed.
  3. **If the SUT crashed:** restore it (re-register backends, wait for pods to
     be ready, verify with a simple query) before proceeding.
  4. **Retry only the failed run** — do NOT restart the entire experiment
     sequence. Resubmit the same plan with the same parameters.
  5. If the retry also fails, log it as a permanent failure and continue with
     the remaining runs. A repeated crash is itself a valid finding.
  6. For non-SUT failures (configuration error, invalid plan), fix the issue
     and resubmit.

### 3e. Log

- Append the experiment to `results.yaml` in the research goal directory.
- Use this structure:

```yaml
experiments:
  - run_id: "<uuid>"
    run_label: "<goal-folder-name>"
    timestamp: "<ISO 8601>"
    description: "<what this experiment tests>"
    plan_file: "plans/<filename>.yaml"
    parameters:
      concurrency: N
      queries: [Q1, Q2]
      hold_for: "120s"
    spec_overrides:
      # only present if engine spec was changed for this run
      be.resources.limits.memory: "8Gi"
    status: completed | failed | skipped
    error: "<error message if failed>"
    results:
      k6:
        # key k6 metrics
        p99_latency_ms: 342
        tps: 120
        error_rate: 0.0
      prometheus:
        # metrics from observability block
        cluster_qps: 145
        avg_memory_bytes: 2147483648
    notes: "<any observations or anomalies>"
```

---

## Phase 4: Analyze

After all planned experiments complete:

1. **Compare results across experiments.** Look for:
   - Trends (does latency grow linearly or exponentially with concurrency?)
   - Thresholds (at what point does behavior change?)
   - Anomalies (unexpected spikes, errors, or plateaus)
2. **Check against the hypothesis.** Is there enough evidence to confirm or reject it?
3. **Decide whether to iterate:**
   - If the data is inconclusive, design follow-up experiments targeting the gap.
     Append them to results.yaml and loop back to Phase 3.
   - If the hypothesis is answered, proceed to Phase 5.
   - Maximum 3 iteration rounds unless the goal file specifies otherwise.

---

## Phase 5: Report

Generate `report.md` in the research goal directory with this structure:

```markdown
# {Title from goal.md}

## Summary
[2-3 sentences directly answering the hypothesis]

## Methodology
- Engine: {name, version}
- Dataset: {name, scale factor}
- Queries: {which queries were tested}
- Parameters varied: {what changed across experiments}
- Duration per experiment: {hold_for value}
- Run label: {goal-folder-name}
- Prometheus metrics collected: {list of metric names}

If the engine spec is constant across all experiments, describe it inline:
- Engine config: {replicas, CPU, memory, notable flags}

If the engine spec varies across experiments (e.g., scalability testing),
list all configurations in a table:

| Config | Replicas | CPU (per node) | Memory (per node) | Notes |
|--------|----------|---------------|-------------------|-------|
| 1x     | 1 BE     | 2 CPU         | 4Gi               | baseline |
| 2x     | 2 BE     | 2 CPU         | 4Gi               | |
| 4x     | 4 BE     | 2 CPU         | 4Gi               | |
| 8x     | 8 BE     | 2 CPU         | 4Gi               | |

## Findings

### {Finding 1 Title}
[Data-backed finding with specific numbers]

### {Finding 2 Title}
[Data-backed finding with specific numbers]

[Include tables comparing metrics across experiments where appropriate]

| Parameter | Metric A | Metric B | Metric C |
|-----------|----------|----------|----------|
| value 1   | ...      | ...      | ...      |
| value 2   | ...      | ...      | ...      |

## Conclusions
[Direct answers to each item in the Success Criteria from goal.md]

## Limitations
[What this investigation did NOT cover; caveats on the results]

## Appendix
- Research goal: {relative path to goal.md}
- Experiment log: {relative path to results.yaml}
- Test plans: {relative path to plans/}
- Crucible run IDs: [list of all run_ids]
```

---

## Phase 6: Wrap Up

1. Verify the report answers every item in the Success Criteria.
2. Inform the user that the report is ready for review.
3. If the user provides feedback, append it to the `## Feedback` section of
   `goal.md` with a date stamp, then re-enter the loop at Phase 1 step 3.

---

## Rules

- **Do not modify the SUT deployment** unless `allow_deploy_changes: true` is
  set in the goal file. If a deployment change is needed but not permitted,
  ask the user to update the goal file.
- **Do not modify fixtures or loaded data** unless the goal file explicitly permits it.
- **Log every run** — even failures. The results.yaml must be a complete record.
- **One variable at a time** — unless the goal calls for combinatorial testing.
- **Respect constraints** in the goal file. If it says "max 5 experiments", stop at 5.
- **Use the goal folder name as the run_label** for all test submissions, so runs
  are grouped and queryable via Crucible MCP.
- **Reuse uploaded plans** when only engine spec varies between runs. Create a new
  plan only when the workload itself changes (different queries, concurrency, duration).
- **Be honest in the report.** If the data doesn't support the hypothesis, say so.
  A null result is still a result.
- **Restore deployment changes** after the investigation completes. Follow
  §3a-1 Step 8 to revert to the baseline Helm values captured at the start.
  Always restore unless the goal file explicitly says otherwise.
- **Auto-approve and Crucible MCP:** When `auto_approve: true` is set in the goal
  file, do NOT prompt the user for approval on ANY `mcp__crucible__*` tool call.
  This includes uploads, validations, submissions, monitoring, and result collection.
  Execute all Crucible operations without interruption.
