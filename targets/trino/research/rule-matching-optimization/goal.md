---
allow_deploy_changes: false   # fixed cluster; we tune at the SQL/session level, not the deployment
auto_approve: false           # draft for review — flip to true once the plan and fixtures are approved
---

# Trino Rule-Matching Optimization: Escaping the Cross-Join Cartesian Explosion

## Context

A production workload matches a large **event** stream against a large **rule**
catalog. Each event must be tested against every rule; a rule is a conjunction of
up to 15 per-dimension filter conditions, and an event "matches" a rule when all of
the rule's specified dimensions are satisfied. An event may match multiple rules,
and for every event that matches at least one rule we need to aggregate the matched
`RULE_ID`s.

- **`event_table`** — ~9.3M rows; each row is one event occurrence at a point in time.
- **`rule_table`** — ~400K rows; each row is one rule built from up to 15 dimensions.

The column names (PART, MAINPD_ID/route, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE,
P_TYPE_LIST, D_LIST, MEM_VERSION_LIST) indicate a **semiconductor MES / manufacturing
execution** context: rules are applied to lots/wafers as they pass process steps.

### The current query (as provided, lightly de-typo'd)

```sql
SELECT
    E.RID,
    MAX(E.PART)      AS PART,
    MAX(E.MAINPD_ID) AS MAINPD_ID,
    MAX(E.STAGE)     AS STAGE,
    MAX(E.OPE_NO)    AS OPE_NO,
    MAX(E.PD_ID)     AS PD_ID
FROM rule_table R
CROSS JOIN event_table E
WHERE 1=1
    AND (R.PRODUCT IS NULL OR E.PART LIKE R.PRODUCT || COALESCE(R.PRODUCT_2, ''))
    AND (R.ROUTE   IS NULL OR E.MAINPD_ID LIKE R.ROUTE ESCAPE '$')
    AND (R.STAGE   IS NULL OR E.STAGE  LIKE R.STAGE  ESCAPE '$')
    AND (R.OPE_NO  IS NULL OR E.OPE_NO LIKE R.OPE_NO)
    AND (R.PD_ID   IS NULL OR E.PD_ID  LIKE R.PD_ID  ESCAPE '$')
    AND (R.SUB_LOT_TYPE IS NULL OR contains(split(R.SUB_LOT_TYPE, ','), E.SUB_LOT_TYPE))
    AND (
        (R.P_TYPE_LIST IS NULL AND R.D_LIST IS NULL AND R.MEM_VERSION_LIST IS NULL)
        OR
        (R.P_TYPE_LIST IS NOT NULL OR R.D_LIST IS NOT NULL)
    )
GROUP BY E.RID;
```

### Why it is slow (root cause)

There is **no equi-join key**, so Trino can only execute this as a **nested-loop
cross join**:

```
9.3M events × 400K rules = 3.7 trillion (event, rule) pairs
```

Each pair evaluates up to 15 predicates, most of them `LIKE` against a
**non-constant** pattern (the pattern comes from a rule column). Dynamic `LIKE` is
far more expensive than constant `LIKE` because the matcher cannot be compiled once
and reused — with hundreds of thousands of distinct patterns the compiled-pattern
cache thrashes. The `(R.X IS NULL OR E.Y LIKE R.X)` shape — where a NULL rule
dimension means "match anything" — is exactly what prevents the optimizer from
turning any dimension into a hash-join key. So the cost is
`trillions × expensive-string-op`.

Two independent levers: **(A) evaluate far fewer pairs**, and **(B) make each pair
cheaper**. (A) is structural and dominates.

### Notes / bugs in the provided query (confirm against the real query)

- `MAX(B.STAGE)` in the original referenced an undefined alias `B` — normalized to
  `E.STAGE` here.
- The original `SELECT` mixed `OPE_ID` (select) with `OPE_NO` (where) — normalized
  to `OPE_NO`.
- The query as written does **not** aggregate `RULE_ID` even though requirement #5
  asks for it. With `GROUP BY E.RID` + `MAX(<event columns>)`, the query is in
  effect a **semi-join** ("which events matched ≥1 rule, with their own
  attributes"). We define the canonical output below to include the matched
  rule_ids so all variants are comparable.

## Engine

trino

## Hypothesis

The bottleneck is the Cartesian nested-loop join, not raw scan throughput.
We claim:

1. **Deduplicating events to their distinct dimension tuples is the load-bearing
   optimization.** A rule's verdict depends only on the dimension values, never on
   which physical event row carried them, so the cross product can be evaluated on
   `count(distinct dimension-tuple)` rows instead of 9.3M. Expected reduction factor
   ≈ `9.3M / distinct_tuples`.
2. **`strpos` reduces per-pair cost but does NOT change the join algorithm.** The
   real matching semantics is **substring containment** (e.g., rule `PRODUCT='ABC'`
   matches event `PART='ABC-1234'`), not exact equality. So we cannot convert these
   predicates to equi-joins; `strpos(E.X, R.X) > 0` is cheaper than dynamic `LIKE`
   but the join stays a nested loop. This makes lever (A) even more important.
3. **Carrying RIDs through `array_agg` during the dedup beats joining back** to the
   9.3M-row table, because it reads the big table only once — *unless* hot dimension
   tuples produce pathologically large arrays, in which case the join-back is safer.

Quantitative expectation: the combined rewrite (dedup + rule pre-filter + precompute
+ strpos) reduces wall-clock and CPU-time by **one to two orders of magnitude**
versus the baseline, with the dedup step contributing the largest single share.

## Metrics of Interest

- End-to-end query wall-clock time per variant
- Total CPU-time (the real cost of the nested loop) per variant
- **Nested-loop join output / input row counts** (from `EXPLAIN ANALYZE`) — the
  direct measure of "how many pairs were evaluated"
- Peak query memory and **spilled bytes** per variant
- Per-operator time breakdown (scan vs join vs aggregation)
- Correctness gate: identical result set across all variants

## Suggested Metrics

PromQL for the cluster-level observability block (Trino exporter on `job="trino"`):

- trino_cpu: `rate(process_cpu_seconds_total{job="trino"}[1m])`
- trino_heap_used: `jvm_memory_bytes_used{job="trino",area="heap"}`
- trino_gc_time: `rate(jvm_gc_collection_seconds_sum{job="trino"}[1m])`
- trino_running_queries: `trino_QueryManager_RunningQueries{job="trino"}`
- trino_running_drivers: `trino_TaskExecutor_RunningSplits{job="trino"}`

Per-query truth comes from `EXPLAIN ANALYZE` (operator rows, CPU, memory, spill),
captured into `results.yaml` per variant.

## Matching Semantics & Data Characteristics (important)

The optimization choices hinge on three facts about the real data. These are the
**first things to measure** (on the real tables) and the **knobs we control** (in
the synthetic dataset):

### 1. Substring containment, not equality

`R.PRODUCT = 'ABC'` should match `E.PART = 'ABC-1234'`. This is the user's example —
a **prefix** match (`ABC` leads `ABC-1234`). Confirm whether the real rule is
"prefix" (`strpos(E.X, R.X) = 1`) or "contains anywhere" (`strpos(E.X, R.X) > 0`);
the two give different results and `= 1` is more selective. Because the semantics is
containment, **equality conversion is incorrect** and a plain hash join is off the
table for these columns.

### 2. Which dimensions carry wildcards

| Dimension (rule col) | Event col | Predicate in original | Treatment |
|---|---|---|---|
| PRODUCT (+PRODUCT_2) | PART | plain `LIKE`, no escape | **strpos candidate** (wildcard-free → substring) |
| OPE_NO | OPE_NO | plain `LIKE`, no escape | **strpos candidate** |
| ROUTE | MAINPD_ID | `LIKE ... ESCAPE '$'` | **keep `LIKE`** — explicit escape signals intentional `%`/`_` wildcards |
| STAGE | STAGE | `LIKE ... ESCAPE '$'` | **keep `LIKE`** |
| PD_ID | PD_ID | `LIKE ... ESCAPE '$'` | **keep `LIKE`** |
| SUB_LOT_TYPE | SUB_LOT_TYPE | `contains(split(...))` | list membership — **pre-split once** |

The presence of `ESCAPE '$'` on ROUTE/STAGE/PD_ID is the tell that those patterns
intentionally contain wildcards — they stay on `LIKE`. A robust implementation
routes **per rule, per dimension**: wildcard-free → `strpos`, has-wildcard → `LIKE`,
`UNION ALL` the two paths.

### 3. Diagnostic pre-measurements (run these before tuning)

```sql
-- (a) dedup payoff: distinct dimension tuples
SELECT count(*) AS distinct_tuples
FROM (SELECT DISTINCT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE FROM event_table);

-- (b) hottest tuple (drives the array_agg skew risk)
SELECT max(c) AS max_group, approx_percentile(c, 0.999) AS p999_group
FROM (SELECT count(*) c FROM event_table GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE);

-- (c) per-dimension wildcard & null fractions on the rule table
SELECT
  count_if(PRODUCT IS NOT NULL)               AS product_set,
  count_if(regexp_like(PRODUCT, '[%_]'))      AS product_wild,
  count_if(OPE_NO  IS NOT NULL)               AS ope_set,
  count_if(regexp_like(OPE_NO,  '[%_]'))      AS ope_wild
  -- …repeat per dimension
FROM rule_table;
```

The win factor of the dedup lever is exactly `row_count / distinct_tuples` (a),
and (b) tells us whether `array_agg(RID)` is safe or whether we must fall back to
the join-back.

## Data Generation Strategy

We do not have the production tables, so we generate **representative synthetic
data** as Iceberg tables on S3 (reusing the existing Trino + Iceberg-JDBC-on-S3
setup from `version-comparison`). Data is generated **deterministically** (all
"random" choices derived by hashing the row sequence index, e.g.
`mod(from_big_endian_64(xxhash64(to_utf8(cast(seq AS varchar)))), pool_size)`) so
runs are reproducible without a seedable RNG.

### Controlled knobs

| Knob | Default | Purpose |
|---|---|---|
| `EVENT_ROWS` | 9,300,000 | match production scale |
| `RULE_ROWS` | 400,000 | match production scale |
| `DISTINCT_TUPLES` | 20,000 | controls dedup payoff (≈465× here); **sweep** 5K / 50K / 500K |
| `HOT_TUPLE_FRACTION` | skewed (Zipfian) | a few tuples carry millions of events → exercises the array_agg skew caveat |
| `RULE_NULL_FRAC` (per dim) | ~0.6 | how often a rule leaves a dimension as wildcard (NULL = match-all) |
| `RULE_WILDCARD_FRAC` (per dim) | ~0.2 of set values | fraction of specified values that carry `%`/`_` (forces the LIKE path) |

### Dimension value pools (cardinalities, tunable)

PRODUCT-family prefixes ~50, route (MAINPD_ID) ~40, STAGE ~30, OPE_NO ~200,
PD_ID ~100, SUB_LOT_TYPE ~5. `PART` is built as
`<product-family-prefix> || '-' || <lot-suffix>` so that (i) the family prefix
repeats across many events (enabling substring matches and controlling tuple
cardinality) while (ii) the lot suffix supplies within-family variety.

### Steps

1. Deploy/confirm Trino (coordinator + 2 workers) with the Iceberg JDBC catalog
   on S3 (see `version-comparison` goal for the catalog wiring).
2. Generate `event_table` and `rule_table` via CTAS into Iceberg using the
   deterministic generators (research-specific fixtures, written next).
3. Run `ANALYZE` on both tables.
4. Run the diagnostic pre-measurements above and record them in `results.yaml`
   (they are part of the findings, not just setup).

## Experiment Design

A **cumulative ladder** of query variants, each adding exactly one lever so its
contribution can be attributed. All variants must produce the **same canonical
output**: for every event matching ≥1 rule, its dimension values and the array of
matched `RULE_ID`s. A correctness gate (identical result sets) runs before any
performance comparison.

### V0 — Baseline (control)

The original CROSS JOIN, faithful to production, with `array_agg(R.RULE_ID)` added
to satisfy requirement #5 and the OR block left as-is.

```sql
SELECT E.RID, array_agg(R.RULE_ID) AS matched_rule_ids,
       MAX(E.PART) PART, MAX(E.MAINPD_ID) MAINPD_ID, MAX(E.STAGE) STAGE,
       MAX(E.OPE_NO) OPE_NO, MAX(E.PD_ID) PD_ID
FROM rule_table R CROSS JOIN event_table E
WHERE (R.PRODUCT IS NULL OR E.PART LIKE R.PRODUCT || COALESCE(R.PRODUCT_2,''))
  AND (R.ROUTE  IS NULL OR E.MAINPD_ID LIKE R.ROUTE ESCAPE '$')
  AND (R.STAGE  IS NULL OR E.STAGE  LIKE R.STAGE  ESCAPE '$')
  AND (R.OPE_NO IS NULL OR E.OPE_NO LIKE R.OPE_NO)
  AND (R.PD_ID  IS NULL OR E.PD_ID  LIKE R.PD_ID  ESCAPE '$')
  AND (R.SUB_LOT_TYPE IS NULL OR contains(split(R.SUB_LOT_TYPE, ','), E.SUB_LOT_TYPE))
  AND ((R.P_TYPE_LIST IS NULL AND R.D_LIST IS NULL AND R.MEM_VERSION_LIST IS NULL)
       OR (R.P_TYPE_LIST IS NOT NULL OR R.D_LIST IS NOT NULL))
GROUP BY E.RID;
```

### V1 — Cheaper per pair (lever B), still a cross join

- Pull the **rule-only predicate** into a pre-filter CTE. The OR block is provably
  equivalent to a single negation — it only excludes rules that set *only*
  `MEM_VERSION_LIST`:
  `NOT (P_TYPE_LIST IS NULL AND D_LIST IS NULL AND MEM_VERSION_LIST IS NOT NULL)`.
  Applying it shrinks the 400K build side **before** the join.
- **Precompute once per rule**: `PRODUCT || COALESCE(PRODUCT_2,'')` → `product_pat`,
  and `split(SUB_LOT_TYPE, ',')` → `sub_lot_arr` (so split is called 400K times, not
  3.7 trillion times).
- Order predicates most-selective-first so `AND` short-circuits early.

```sql
WITH rules AS (
  SELECT RULE_ID,
         PRODUCT, PRODUCT || COALESCE(PRODUCT_2,'') AS product_pat,
         ROUTE, STAGE, OPE_NO, PD_ID,
         CASE WHEN SUB_LOT_TYPE IS NULL THEN NULL ELSE split(SUB_LOT_TYPE, ',') END AS sub_lot_arr
  FROM rule_table
  WHERE NOT (P_TYPE_LIST IS NULL AND D_LIST IS NULL AND MEM_VERSION_LIST IS NOT NULL)
)
SELECT E.RID, array_agg(R.RULE_ID) AS matched_rule_ids, /* …MAX(event cols)… */
FROM rules R CROSS JOIN event_table E
WHERE (R.PRODUCT IS NULL OR E.PART LIKE R.product_pat)
  AND (R.OPE_NO  IS NULL OR E.OPE_NO LIKE R.OPE_NO)
  AND (R.ROUTE   IS NULL OR E.MAINPD_ID LIKE R.ROUTE ESCAPE '$')
  AND (R.STAGE   IS NULL OR E.STAGE LIKE R.STAGE ESCAPE '$')
  AND (R.PD_ID   IS NULL OR E.PD_ID LIKE R.PD_ID ESCAPE '$')
  AND (R.sub_lot_arr IS NULL OR contains(R.sub_lot_arr, E.SUB_LOT_TYPE))
GROUP BY E.RID;
```

### V2 — Dedup events to distinct tuples + join back (lever A)

```sql
WITH rules AS ( /* …as in V1… */ ),
event_dims AS (
  SELECT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
  FROM event_table
  GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
),
matched_dims AS (
  SELECT ed.*, array_agg(R.RULE_ID) AS matched_rule_ids
  FROM event_dims ed JOIN rules R ON ( /* the 6 predicates against ed.* */ )
  GROUP BY ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE
)
SELECT E.RID, m.matched_rule_ids
FROM event_table E JOIN matched_dims m
  ON  E.PART IS NOT DISTINCT FROM m.PART
  AND E.MAINPD_ID IS NOT DISTINCT FROM m.MAINPD_ID
  AND E.STAGE IS NOT DISTINCT FROM m.STAGE
  AND E.OPE_NO IS NOT DISTINCT FROM m.OPE_NO
  AND E.PD_ID IS NOT DISTINCT FROM m.PD_ID
  AND E.SUB_LOT_TYPE IS NOT DISTINCT FROM m.SUB_LOT_TYPE;
```

`IS NOT DISTINCT FROM` is null-safe equality and is hash-joinable. This reads the
9.3M table **twice** (once to dedup, once to join back).

### V3 — Dedup + carry RIDs via `array_agg` (single scan of the big table)

Reads the 9.3M table **once**; RIDs ride along as an aggregate, so the whole RID
group inherits the same matched rule_ids.

```sql
WITH rules AS ( /* …as in V1… */ ),
event_dims AS (
  SELECT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE, array_agg(RID) AS rids
  FROM event_table
  GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
),
matched AS (
  SELECT ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE,
         arbitrary(ed.rids)   AS rids,        -- rids identical within a group → pick one
         array_agg(R.RULE_ID) AS matched_rule_ids
  FROM event_dims ed JOIN rules R ON ( /* the 6 predicates */ )
  GROUP BY ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE
)
SELECT rids, matched_rule_ids FROM matched;  -- compact grouped form; UNNEST(rids) only if per-RID rows are needed
```

Key details captured from the design discussion:
- Use `arbitrary(ed.rids)`, **not** `GROUP BY ed.rids` (don't put a big array in the
  group key).
- Aggregate `RULE_ID` per tuple **before** any explode, so the `rids` array is not
  duplicated once per matched rule.
- **Defer `UNNEST(rids)` to the very end, or skip it entirely** if the consumer can
  take the grouped form — that avoids ever materializing 9.3M output rows.

### V4 — V3 + `strpos` for the wildcard-free columns (lever B, on top of A)

Replace dynamic `LIKE` with `strpos` for PRODUCT and OPE_NO (substring semantics),
keep `LIKE ... ESCAPE '$'` for ROUTE/STAGE/PD_ID:

```sql
ON (R.PRODUCT IS NULL OR strpos(ed.PART, R.product_pat) > 0)   -- or = 1 for prefix-only
AND (R.OPE_NO  IS NULL OR strpos(ed.OPE_NO, R.OPE_NO) > 0)
AND (R.ROUTE   IS NULL OR ed.MAINPD_ID LIKE R.ROUTE ESCAPE '$')
AND (R.STAGE   IS NULL OR ed.STAGE LIKE R.STAGE ESCAPE '$')
AND (R.PD_ID   IS NULL OR ed.PD_ID LIKE R.PD_ID ESCAPE '$')
AND (R.sub_lot_arr IS NULL OR contains(R.sub_lot_arr, ed.SUB_LOT_TYPE))
```

Edge case to verify: `strpos(x, '')` returns 1 in Trino (empty needle = match-all);
ensure empty rule values are intended as match-all, else guard them.

### V5 — (Advanced, optional) escape the nested loop for prefix matches

Only applicable if PRODUCT matching is **prefix** (`strpos = 1`) and rule prefixes
come in a **small number of distinct lengths**. Then real hash joins are possible by
doing one equi-join per length and `UNION ALL`-ing: `substr(E.PART,1,L) = R.PRODUCT`
for the length-`L` rules. For substring-anywhere semantics the analog is an n-gram
inverted-index pre-filter — noted as the escalation path, not a V-variant.

### Test matrix

| Run | Variant | Lever added | Big-table scans | Join type |
|-----|---------|-------------|-----------------|-----------|
| 1 | V0 | — (baseline) | 1 | nested loop |
| 2 | V1 | rule pre-filter + precompute + predicate order | 1 | nested loop |
| 3 | V2 | + dedup to distinct tuples (join back) | 2 | nested loop on tuples + hash join back |
| 4 | V3 | + carry RIDs via array_agg | 1 | nested loop on tuples |
| 5 | V4 | + strpos for wildcard-free dims | 1 | nested loop on tuples |
| 6 | V5 | + prefix per-length equi-join (if applicable) | 1 | hash join |

Plus a **dedup-payoff sweep**: re-run V4 at `DISTINCT_TUPLES` ∈ {5K, 20K, 50K, 500K}
to plot latency vs distinct-tuple count, and a **skew run**: V3 vs V2 under the
hot-tuple distribution to find the max-group-size where `array_agg` degrades/OOMs
and the join-back becomes preferable.

## Constraints

- Fixed cluster (1 coordinator + 2 workers, as in `version-comparison`); no Helm /
  resource / replica changes (`allow_deploy_changes: false`).
- Generate the dataset **once**; every query variant runs against the identical
  Iceberg tables. Data generation is deterministic and reproducible.
- Hold Trino session properties constant across V0–V4 (`join_distribution_type`,
  `task.concurrency`, spill settings) unless a property is explicitly the subject of
  a run; record the settings used.
- **Correctness gate first**: prove all variants return identical
  `(event → matched_rule_ids)` sets before comparing performance. strpos and dedup
  must not change results.
- Each variant is a single batch query; capture `EXPLAIN ANALYZE` (operator rows,
  CPU, peak memory, spill) into `results.yaml`.
- The baseline V0 may be extremely slow at full scale — set a sane statement timeout
  and, if V0 cannot complete, record the timeout and compare against a reduced-scale
  V0 instead (note the reduction).

## Success Criteria

- **Ladder table**: wall-clock, CPU-time, peak memory, spilled bytes, and
  nested-loop output-row count for V0 → V4 (→V5), with the speedup factor vs V0 at
  each rung — so each lever's contribution is attributed.
- Confirmation that the dedup step (V1→V2/V3) is the single largest contributor, and
  by how much, at the default cardinality.
- **Dedup-payoff curve**: latency vs `DISTINCT_TUPLES`, validating the
  `rows / distinct_tuples` win-factor model.
- **strpos vs LIKE** isolated: the V3→V4 delta quantifies the per-pair cost saving
  of `strpos` over dynamic `LIKE` (with the join algorithm held constant).
- **Skew finding**: at what hottest-tuple size does `array_agg` (V3) degrade or
  fail, and the recommendation for when to prefer the join-back (V2) instead.
- A **recommended final query**, plus a short decision guide: array_agg-grouped vs
  join-back, and `strpos > 0` vs `= 1`.
- Guidance on **when to escalate beyond SQL** — prefix per-length equi-join (V5),
  n-gram inverted index, or a dedicated rules engine — with the data conditions that
  justify each.

## Appendix — original query, verbatim as provided

```sql
SELECT
    E.RID,
    MAX(E.PART) AS PART,
    MAX(E.MAINPD_ID) AS MAINPD_ID,
    MAX(B.STAGE) AS STAGE,
    MAX(OPE_ID) AS OPE_ID,
    MAX(PD_ID) AS PD_ID
FROM rule_table R
CROSS JOIN event_table E
WHERE 1=1
    AND (R.PRODUCT IS NULL OR E.PART LIKE R.PRODUCT || COALESCE(R.PRODUCT_2, ''))
    AND (R.ROUTE IS NULL OR E.MAINPD_ID LIKE R.ROUTE ESCAPE '$')
    AND (R.STAGE IS NULL OR E.STAGE LIKE R.STAGE ESCAPE '$')
    AND (R.OPE_NO IS NULL OR E.OPE_NO LIKE R.OPE_NO)
    AND (R.PD_ID IS NULL OR E.PD_ID LIKE R.PD_ID ESCAPE '$')
    AND (R.SUB_LOT_TYPE IS NULL OR contains(split(R.SUB_LOT_TYPE, ','), E.SUB_LOT_TYPE))
    AND (
        (R.P_TYPE_LIST IS NULL AND R.D_LIST IS NULL AND R.MEM_VERSION_LIST IS NULL)
        OR
        (R.P_TYPE_LIST IS NOT NULL OR R.D_LIST IS NOT NULL)
    )
GROUP BY E.RID
```
