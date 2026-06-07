-- =============================================================================
-- Correctness gate — proves V0 and V4 return the identical (RID -> matched rule
-- set). Run with:  USE iceberg.rule_match;
--
-- RUN AT REDUCED SCALE so V0 can finish (see README): regenerate event_table with
-- sequence(1, 50) and rule_table with sequence(1, 5). Expect BOTH n = 0.
-- If either is non-zero, a rewrite changed results -- do not trust the benchmark.
-- =============================================================================
WITH
-- ---- V0: baseline, normalized to (rid, sorted rule set) ----------------------
v0 AS (
  SELECT E.RID AS rid, array_sort(array_agg(R.RULE_ID)) AS rs
  FROM rule_table R
  CROSS JOIN event_table E
  WHERE (R.PRODUCT IS NULL OR E.PART LIKE R.PRODUCT || COALESCE(R.PRODUCT_2, ''))
    AND (R.ROUTE   IS NULL OR E.MAINPD_ID LIKE R.ROUTE ESCAPE '$')
    AND (R.STAGE   IS NULL OR E.STAGE  LIKE R.STAGE  ESCAPE '$')
    AND (R.OPE_NO  IS NULL OR E.OPE_NO LIKE R.OPE_NO)
    AND (R.PD_ID   IS NULL OR E.PD_ID  LIKE R.PD_ID  ESCAPE '$')
    AND (R.SUB_LOT_TYPE IS NULL OR contains(split(R.SUB_LOT_TYPE, ','), E.SUB_LOT_TYPE))
    AND ((R.P_TYPE_LIST IS NULL AND R.D_LIST IS NULL AND R.MEM_VERSION_LIST IS NULL)
         OR (R.P_TYPE_LIST IS NOT NULL OR R.D_LIST IS NOT NULL))
  GROUP BY E.RID
),
-- ---- V4: dedup + array_agg + strpos routing ----------------------------------
rules AS (
  SELECT
    RULE_ID, PRODUCT, OPE_NO, ROUTE, STAGE, PD_ID,
    PRODUCT || COALESCE(PRODUCT_2, '')                                            AS product_pat,
    CASE WHEN SUB_LOT_TYPE IS NULL THEN NULL ELSE split(SUB_LOT_TYPE, ',') END    AS sub_lot_arr,
    (PRODUCT || COALESCE(PRODUCT_2, '')) LIKE '%\%' ESCAPE '\'
      AND NOT regexp_like(
            substr(PRODUCT || COALESCE(PRODUCT_2, ''), 1,
                   length(PRODUCT || COALESCE(PRODUCT_2, '')) - 1), '[%_]')        AS product_simple,
    substr(PRODUCT || COALESCE(PRODUCT_2, ''), 1,
           length(PRODUCT || COALESCE(PRODUCT_2, '')) - 1)                         AS product_literal,
    OPE_NO LIKE '%\%' ESCAPE '\'
      AND NOT regexp_like(substr(OPE_NO, 1, length(OPE_NO) - 1), '[%_]')           AS ope_simple,
    substr(OPE_NO, 1, length(OPE_NO) - 1)                                          AS ope_literal
  FROM rule_table
  WHERE NOT (P_TYPE_LIST IS NULL AND D_LIST IS NULL AND MEM_VERSION_LIST IS NOT NULL)
),
event_dims AS (
  SELECT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE, array_agg(RID) AS rids
  FROM event_table
  GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
),
matched AS (
  SELECT
    arbitrary(ed.rids)   AS rids,
    array_agg(R.RULE_ID) AS matched_rule_ids
  FROM event_dims ed
  JOIN rules R
    ON ( R.OPE_NO IS NULL
         OR (R.ope_simple     AND strpos(ed.OPE_NO, R.ope_literal) = 1)
         OR (NOT R.ope_simple AND ed.OPE_NO LIKE R.OPE_NO) )
   AND ( R.PD_ID IS NULL OR ed.PD_ID LIKE R.PD_ID ESCAPE '$' )
   AND ( R.PRODUCT IS NULL
         OR (R.product_simple     AND strpos(ed.PART, R.product_literal) = 1)
         OR (NOT R.product_simple AND ed.PART LIKE R.product_pat) )
   AND ( R.STAGE IS NULL OR ed.STAGE LIKE R.STAGE ESCAPE '$' )
   AND ( R.ROUTE IS NULL OR ed.MAINPD_ID LIKE R.ROUTE ESCAPE '$' )
   AND ( R.sub_lot_arr IS NULL OR contains(R.sub_lot_arr, ed.SUB_LOT_TYPE) )
  GROUP BY ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE
),
v4 AS (
  SELECT rid, array_sort(matched_rule_ids) AS rs
  FROM matched CROSS JOIN UNNEST(rids) AS t(rid)
)
-- ---- diff both directions; both must be 0 ------------------------------------
SELECT 'in_v0_not_v4' AS diff, count(*) AS n FROM (SELECT * FROM v0 EXCEPT SELECT * FROM v4)
UNION ALL
SELECT 'in_v4_not_v0' AS diff, count(*) AS n FROM (SELECT * FROM v4 EXCEPT SELECT * FROM v0);
