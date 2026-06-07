# Fixtures — Trino rule-matching optimization

Research-specific fixtures for `../goal.md`. These generate a representative
synthetic dataset and provide the query-variant ladder (V0→V5), diagnostics, and a
correctness gate.

## Prerequisites

- Trino deployed with the Iceberg JDBC catalog on S3 (see
  `targets/trino/research/version-comparison/goal.md` for the catalog wiring).
- A schema to hold the tables:

  ```sql
  CREATE SCHEMA IF NOT EXISTS iceberg.rule_match;
  ```

- All **query** files (`v*.sql`, `diagnostics.sql`, `correctness_gate.sql`) assume
  the session default catalog/schema is set:

  ```sql
  USE iceberg.rule_match;
  ```

  The **generator** files (`gen_*.sql`) fully-qualify their target tables, so they
  do not depend on `USE`.

## Run order

```text
1. CREATE SCHEMA IF NOT EXISTS iceberg.rule_match;
2. gen_event_table.sql        -- creates iceberg.rule_match.event_table
3. gen_rule_table.sql         -- creates iceberg.rule_match.rule_table
4. ANALYZE iceberg.rule_match.event_table;
   ANALYZE iceberg.rule_match.rule_table;
5. diagnostics.sql            -- record dedup factor, hottest tuple, wildcard fractions
6. v0_baseline.sql ... v5_prefix_equijoin.sql   -- time each (capture EXPLAIN ANALYZE)
7. correctness_gate.sql       -- run at REDUCED scale; expect both diff counts = 0
```

## Knobs

The dataset is **deterministic** — every value is derived by hashing the row index
(`from_big_endian_64(xxhash64(to_utf8(...)))`), so re-running produces identical
tables without `random()`. Knobs live at the top of the generators:

| Knob | File | Default | Effect |
|---|---|---|---|
| `EVENT_ROWS` | `gen_event_table.sql` | `9300 * 1000` = 9.3M | total events (set first sequence bound) |
| `DISTINCT_TUPLES` | `gen_event_table.sql` (`params`) | 20000 | distinct dimension contexts; dedup factor ≈ `EVENT_ROWS / DISTINCT_TUPLES` |
| `ZIPF_EXP` | `gen_event_table.sql` (`params`) | 1.0 (uniform) | tuple-frequency skew; **2.5** makes a few very hot tuples (stresses `array_agg`) |
| `RULE_ROWS` | `gen_rule_table.sql` | `400 * 1000` = 400K | total rules (set first sequence bound) |
| `NULL_PCT` | `gen_rule_table.sql` | `< 60` (40% set) | per-dimension chance a rule leaves a dimension as wildcard (NULL = match-all) |
| `WILD_PCT` | `gen_rule_table.sql` | `< 20` | of the SET values, fraction that are genuine LIKE wildcards (force the LIKE path) |

### Sweeps called for by the goal

- **Dedup-payoff curve**: regenerate `event_table` at `DISTINCT_TUPLES` ∈
  {5000, 20000, 50000, 500000}, re-run V4, plot latency vs distinct tuples.
- **Skew run**: regenerate `event_table` with `ZIPF_EXP = 2.5`, compare V3 (array_agg)
  vs V2 (join-back) — find the hottest-tuple size where V3 degrades/OOMs.

## Value pools (shared by both generators — must match for rules to hit events)

| Dimension | Event column | Pool | Example value |
|---|---|---|---|
| product family | `PART` prefix | 50 | `P012` (PART = `P012-3456`) |
| route | `MAINPD_ID` | 40 | `R07` |
| stage | `STAGE` | 30 | `S07` |
| operation | `OPE_NO` | 200 | `OP042` |
| product id | `PD_ID` | 100 | `PD42` |
| sub-lot type | `SUB_LOT_TYPE` | 5 | one of `NORMAL,ENG,HOLD,RWK,SKIP` |

## Matching model

- **PRODUCT** — prefix match on the family code. Simple rules:
  `PRODUCT='P012'`, `PRODUCT_2='%'` → pattern `P012%`. Wildcard rules:
  `PRODUCT='%P012%'`, `PRODUCT_2=NULL`. V4 routes simple→`strpos(...)=1`,
  wildcard→`LIKE`.
- **OPE_NO** — prefix match. Simple: `OP042%`; wildcard: `%OP042%`. Same V4 routing.
- **ROUTE / STAGE / PD_ID** — kept on `LIKE ... ESCAPE '$'` in **all** variants
  (these are the genuine-wildcard dimensions; event values are exact categorical
  codes, so a wildcard-free rule value behaves as exact match).
- **SUB_LOT_TYPE** — comma list, tested with `contains(split(...), E.SUB_LOT_TYPE)`.
- **P_TYPE_LIST / D_LIST / MEM_VERSION_LIST** — feed the rule-only OR block. ~10% of
  rules are "mem-only" and are dropped by the V1 pre-filter
  (`NOT (P_TYPE_LIST IS NULL AND D_LIST IS NULL AND MEM_VERSION_LIST IS NOT NULL)`).

All variants are constructed to return the **identical** result
(`RID → set of matched RULE_IDs`); `correctness_gate.sql` proves V0 ≡ V4.

## Reduced-scale correctness run

V0 cannot finish at full scale (3.7T pair evaluations). To validate equivalence,
regenerate both tables small, then run the gate:

- `gen_event_table.sql`: change `sequence(1, 9300)` → `sequence(1, 50)` (50K rows)
  and `params.distinct_tuples` → e.g. 2000.
- `gen_rule_table.sql`: change `sequence(1, 400)` → `sequence(1, 5)` (5K rules).
- Run `correctness_gate.sql` — both `n` values must be `0`.

## Files

| File | Purpose |
|---|---|
| `gen_event_table.sql` | synthetic `event_table` (deterministic) |
| `gen_rule_table.sql` | synthetic `rule_table` (deterministic) |
| `diagnostics.sql` | distinct-tuple count, hottest tuple, wildcard/null fractions |
| `v0_baseline.sql` | control — original CROSS JOIN |
| `v1_prefilter_precompute.sql` | + rule pre-filter, precomputed concat/split, predicate order |
| `v2_dedup_joinback.sql` | + dedup to distinct tuples, hash-join back (2 scans) |
| `v3_dedup_arrayagg.sql` | + carry RIDs via `array_agg` (1 scan) |
| `v4_strpos.sql` | + `strpos` for wildcard-free PRODUCT/OPE_NO |
| `v5_prefix_equijoin.sql` | OPTIONAL — hash join for simple PRODUCT prefixes |
| `correctness_gate.sql` | proves V0 ≡ V4 (run at reduced scale) |
| `drop_tables.sql` | teardown |
