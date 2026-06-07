-- =============================================================================
-- Generate synthetic event_table  (rule-matching-optimization research)
-- =============================================================================
-- Deterministic: every value is derived by hashing the row index, so the table
-- is reproducible across runs (no random()).
--
-- Prereq:  CREATE SCHEMA IF NOT EXISTS iceberg.rule_match;
--
-- KNOBS
--   EVENT_ROWS      : product of the two sequence bounds below.
--                     full scale       = 9300 * 1000 = 9,300,000
--                     correctness run  =   50 * 1000 =    50,000  (set g1 bound to 50)
--   DISTINCT_TUPLES : params.distinct_tuples — number of distinct dimension
--                     contexts. Dedup payoff factor ~ EVENT_ROWS / DISTINCT_TUPLES.
--                     sweep: 5000 / 20000 / 50000 / 500000
--   ZIPF_EXP        : params.zipf_exp — 1.0 = uniform tuple frequency.
--                     skew run: 2.5 (a few very hot tuples => large array_agg groups)
-- =============================================================================

DROP TABLE IF EXISTS iceberg.rule_match.event_table;

CREATE TABLE iceberg.rule_match.event_table
WITH (format = 'PARQUET') AS
WITH params AS (
  SELECT CAST(20000 AS bigint) AS distinct_tuples,
         CAST(1.0   AS double) AS zipf_exp
),
ids AS (
  SELECT (a - 1) * 1000 + b AS rid
  FROM UNNEST(sequence(1, 9300)) AS g1(a)        -- EVENT_ROWS = 9300 * 1000
  CROSS JOIN UNNEST(sequence(1, 1000)) AS g2(b)
),
assigned AS (
  SELECT
    i.rid,
    -- skewed assignment into [0, distinct_tuples): power(u, zipf_exp) concentrates
    -- mass on low tuple ids when zipf_exp > 1.
    CAST(floor(
      power(
        ((from_big_endian_64(xxhash64(to_utf8(CAST(i.rid AS varchar) || '|tuple'))) % 1000000) + 1000000) % 1000000 / 1000000e0,
        p.zipf_exp
      ) * p.distinct_tuples
    ) AS bigint) AS tuple_id
  FROM ids i CROSS JOIN params p
),
dims AS (
  SELECT
    rid,
    (from_big_endian_64(xxhash64(to_utf8(CAST(tuple_id AS varchar) || '|fam'))) % 50    + 50   ) % 50    AS fam,
    (from_big_endian_64(xxhash64(to_utf8(CAST(tuple_id AS varchar) || '|lot'))) % 10000 + 10000) % 10000 AS lot,
    (from_big_endian_64(xxhash64(to_utf8(CAST(tuple_id AS varchar) || '|rte'))) % 40    + 40   ) % 40    AS rte,
    (from_big_endian_64(xxhash64(to_utf8(CAST(tuple_id AS varchar) || '|stg'))) % 30    + 30   ) % 30    AS stg,
    (from_big_endian_64(xxhash64(to_utf8(CAST(tuple_id AS varchar) || '|ope'))) % 200   + 200  ) % 200   AS ope,
    (from_big_endian_64(xxhash64(to_utf8(CAST(tuple_id AS varchar) || '|pd' ))) % 100   + 100  ) % 100   AS pd,
    (from_big_endian_64(xxhash64(to_utf8(CAST(tuple_id AS varchar) || '|slt'))) % 5     + 5    ) % 5     AS slt
  FROM assigned
)
SELECT
  rid                                                                              AS RID,
  -- PART = product-family prefix + '-' + lot suffix  (the prefix is what rules match on)
  'P'  || lpad(CAST(fam AS varchar), 3, '0') || '-' || lpad(CAST(lot AS varchar), 4, '0') AS PART,
  'R'  || lpad(CAST(rte AS varchar), 2, '0')                                       AS MAINPD_ID,
  'S'  || lpad(CAST(stg AS varchar), 2, '0')                                       AS STAGE,
  'OP' || lpad(CAST(ope AS varchar), 3, '0')                                       AS OPE_NO,
  'PD' || lpad(CAST(pd  AS varchar), 2, '0')                                       AS PD_ID,
  element_at(ARRAY['NORMAL','ENG','HOLD','RWK','SKIP'], CAST(slt AS integer) + 1)  AS SUB_LOT_TYPE
FROM dims;
