-- =============================================================================
-- Diagnostics — run with:  USE iceberg.rule_match;
-- Each block below is a separate statement. Record results in ../results.yaml;
-- they are findings, not just setup (they decide each lever's payoff).
-- =============================================================================

-- (a) Dedup payoff: distinct dimension tuples vs total rows.
--     The dedup lever's win factor is ~ event_rows / distinct_tuples.
SELECT
  (SELECT count(*) FROM event_table)                              AS event_rows,
  count(*)                                                        AS distinct_tuples,
  CAST((SELECT count(*) FROM event_table) AS double) / count(*)   AS dedup_factor
FROM (
  SELECT DISTINCT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
  FROM event_table
);

-- (b) Hottest tuple — drives the array_agg(RID) skew risk in V3/V4.
--     If max_group is in the millions, prefer V2 (join-back) for per-RID output.
SELECT
  max(c)                        AS max_group,
  approx_percentile(c, 0.999)   AS p999_group,
  avg(c)                        AS avg_group
FROM (
  SELECT count(*) AS c
  FROM event_table
  GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
);

-- (c) Per-dimension set/wildcard fractions on the rule table, plus how many rules
--     are strpos-eligible and how many the V1 pre-filter drops.
SELECT
  count(*)                                                                   AS rules,
  count_if(PRODUCT IS NOT NULL)                                              AS product_set,
  count_if((PRODUCT || COALESCE(PRODUCT_2,'')) LIKE '%\%' ESCAPE '\'
           AND NOT regexp_like(
                 substr(PRODUCT || COALESCE(PRODUCT_2,''), 1,
                        length(PRODUCT || COALESCE(PRODUCT_2,'')) - 1), '[%_]'))
                                                                             AS product_strpos_eligible,
  count_if(OPE_NO IS NOT NULL)                                               AS ope_set,
  count_if(OPE_NO LIKE '%\%' ESCAPE '\'
           AND NOT regexp_like(substr(OPE_NO, 1, length(OPE_NO) - 1), '[%_]'))
                                                                             AS ope_strpos_eligible,
  count_if(ROUTE IS NOT NULL)                                               AS route_set,
  count_if(STAGE IS NOT NULL)                                               AS stage_set,
  count_if(PD_ID IS NOT NULL)                                               AS pd_set,
  count_if(SUB_LOT_TYPE IS NOT NULL)                                        AS sublot_set,
  count_if(P_TYPE_LIST IS NULL AND D_LIST IS NULL AND MEM_VERSION_LIST IS NOT NULL)
                                                                             AS dropped_by_prefilter
FROM rule_table;
