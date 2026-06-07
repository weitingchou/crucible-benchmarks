-- =============================================================================
-- Generate synthetic rule_table  (rule-matching-optimization research)
-- =============================================================================
-- Deterministic (hash of the rule index). Values are drawn from the SAME pools as
-- event_table so rules actually match events.
--
-- Prereq:  CREATE SCHEMA IF NOT EXISTS iceberg.rule_match;
--
-- KNOBS
--   RULE_ROWS : product of the two sequence bounds (full = 400*1000 = 400,000;
--               correctness run = 5*1000 = 5,000 — set g1 bound to 5).
--   NULL_PCT  : per-dimension chance a rule leaves the dimension as a wildcard
--               (NULL = match-all). Hard-coded as `< 60` below (=> 40% set).
--   WILD_PCT  : of the SET values, fraction that are genuine LIKE wildcards
--               (force the LIKE path in V4). Hard-coded as `< 20` below.
--
-- Matching model (see README):
--   PRODUCT  prefix: simple 'Pxxx' + PRODUCT_2 '%'  => 'Pxxx%';  wildcard '%Pxxx%'.
--   OPE_NO   prefix: simple 'OPyyy%';                            wildcard '%OPyyy%'.
--   ROUTE/STAGE/PD_ID  kept on LIKE in all variants.
--   SUB_LOT_TYPE  comma list (1-2 types).
--   P_TYPE_LIST/D_LIST/MEM_VERSION_LIST  feed the rule-only block; ~10% mem-only.
-- =============================================================================

DROP TABLE IF EXISTS iceberg.rule_match.rule_table;

CREATE TABLE iceberg.rule_match.rule_table
WITH (format = 'PARQUET') AS
WITH ids AS (
  SELECT (a - 1) * 1000 + b AS rule_id
  FROM UNNEST(sequence(1, 400)) AS g1(a)         -- RULE_ROWS = 400 * 1000
  CROSS JOIN UNNEST(sequence(1, 1000)) AS g2(b)
),
h AS (
  SELECT rule_id,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|p_set'))) % 100 + 100) % 100 AS p_set,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|p_fam'))) %  50 +  50) %  50 AS p_fam,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|p_wld'))) % 100 + 100) % 100 AS p_wld,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|o_set'))) % 100 + 100) % 100 AS o_set,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|o_ope'))) % 200 + 200) % 200 AS o_ope,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|o_wld'))) % 100 + 100) % 100 AS o_wld,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|r_set'))) % 100 + 100) % 100 AS r_set,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|r_rte'))) %  40 +  40) %  40 AS r_rte,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|r_wld'))) % 100 + 100) % 100 AS r_wld,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|s_set'))) % 100 + 100) % 100 AS s_set,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|s_stg'))) %  30 +  30) %  30 AS s_stg,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|s_wld'))) % 100 + 100) % 100 AS s_wld,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|d_set'))) % 100 + 100) % 100 AS d_set,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|d_pd' ))) % 100 + 100) % 100 AS d_pd,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|d_wld'))) % 100 + 100) % 100 AS d_wld,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|t_set'))) % 100 + 100) % 100 AS t_set,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|t_a'  ))) %   5 +   5) %   5 AS t_a,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|t_b'  ))) %   5 +   5) %   5 AS t_b,
    (from_big_endian_64(xxhash64(to_utf8(CAST(rule_id AS varchar)||'|blk'  ))) % 100 + 100) % 100 AS blk
  FROM ids
),
codes AS (
  SELECT h.*,
    'P'  || lpad(CAST(p_fam AS varchar), 3, '0') AS p_code,
    'OP' || lpad(CAST(o_ope AS varchar), 3, '0') AS o_code,
    'R'  || lpad(CAST(r_rte AS varchar), 2, '0') AS r_code,
    'S'  || lpad(CAST(s_stg AS varchar), 2, '0') AS s_code,
    'PD' || lpad(CAST(d_pd  AS varchar), 2, '0') AS d_code
  FROM h
)
SELECT
  rule_id AS RULE_ID,
  -- PRODUCT / PRODUCT_2 (prefix match; PRODUCT_2 supplies the trailing wildcard)
  CASE WHEN p_set < 60 THEN NULL
       WHEN p_wld < 20 THEN '%' || p_code || '%'
       ELSE p_code END                                  AS PRODUCT,
  CASE WHEN p_set < 60 THEN NULL
       WHEN p_wld < 20 THEN NULL
       ELSE '%' END                                     AS PRODUCT_2,
  -- ROUTE (kept on LIKE in all variants)
  CASE WHEN r_set < 60 THEN NULL
       WHEN r_wld < 20 THEN substr(r_code, 1, 2) || '%'
       ELSE r_code END                                  AS ROUTE,
  -- STAGE (kept on LIKE)
  CASE WHEN s_set < 60 THEN NULL
       WHEN s_wld < 20 THEN substr(s_code, 1, 2) || '%'
       ELSE s_code END                                  AS STAGE,
  -- OPE_NO (strpos candidate: prefix pattern carries the wildcard itself)
  CASE WHEN o_set < 60 THEN NULL
       WHEN o_wld < 20 THEN '%' || o_code || '%'
       ELSE o_code || '%' END                           AS OPE_NO,
  -- PD_ID (kept on LIKE)
  CASE WHEN d_set < 60 THEN NULL
       WHEN d_wld < 20 THEN substr(d_code, 1, 3) || '%'
       ELSE d_code END                                  AS PD_ID,
  -- SUB_LOT_TYPE comma list (1-2 types)
  CASE WHEN t_set < 60 THEN NULL
       WHEN t_a = t_b THEN element_at(ARRAY['NORMAL','ENG','HOLD','RWK','SKIP'], CAST(t_a AS integer) + 1)
       ELSE element_at(ARRAY['NORMAL','ENG','HOLD','RWK','SKIP'], CAST(t_a AS integer) + 1)
            || ',' || element_at(ARRAY['NORMAL','ENG','HOLD','RWK','SKIP'], CAST(t_b AS integer) + 1)
       END                                              AS SUB_LOT_TYPE,
  -- rule-only block: blk<10 => mem-only (dropped by V1 pre-filter), else passes
  CASE WHEN blk >= 10 AND blk < 40 THEN 'PT' || CAST(blk AS varchar) ELSE NULL END AS P_TYPE_LIST,
  CASE WHEN blk >= 40 AND blk < 60 THEN 'D'  || CAST(blk AS varchar) ELSE NULL END AS D_LIST,
  CASE WHEN blk < 10               THEN 'MV' || CAST(blk AS varchar) ELSE NULL END AS MEM_VERSION_LIST
FROM codes;
