-- V4 — V3 + strpos for the wildcard-free PRODUCT/OPE_NO patterns (lever B on A).
-- Per-rule routing: a simple `literal%` prefix -> strpos(...) = 1 (no pattern
-- compilation); any genuine-wildcard pattern -> LIKE. Results are identical to V0
-- because `x LIKE lit || '%'` (lit wildcard-free) is exactly `strpos(x, lit) = 1`.
-- Run with:  USE iceberg.rule_match;
WITH rules AS (
  SELECT
    RULE_ID,
    PRODUCT, OPE_NO, ROUTE, STAGE, PD_ID,
    PRODUCT || COALESCE(PRODUCT_2, '')                                            AS product_pat,
    CASE WHEN SUB_LOT_TYPE IS NULL THEN NULL ELSE split(SUB_LOT_TYPE, ',') END    AS sub_lot_arr,
    -- PRODUCT classification: simple = ends with a single '%' and the rest has no %/_
    (PRODUCT || COALESCE(PRODUCT_2, '')) LIKE '%\%' ESCAPE '\'
      AND NOT regexp_like(
            substr(PRODUCT || COALESCE(PRODUCT_2, ''), 1,
                   length(PRODUCT || COALESCE(PRODUCT_2, '')) - 1), '[%_]')        AS product_simple,
    substr(PRODUCT || COALESCE(PRODUCT_2, ''), 1,
           length(PRODUCT || COALESCE(PRODUCT_2, '')) - 1)                         AS product_literal,
    -- OPE_NO classification
    OPE_NO LIKE '%\%' ESCAPE '\'
      AND NOT regexp_like(substr(OPE_NO, 1, length(OPE_NO) - 1), '[%_]')           AS ope_simple,
    substr(OPE_NO, 1, length(OPE_NO) - 1)                                          AS ope_literal
  FROM rule_table
  WHERE NOT (P_TYPE_LIST IS NULL AND D_LIST IS NULL AND MEM_VERSION_LIST IS NOT NULL)
),
event_dims AS (
  SELECT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE,
         array_agg(RID) AS rids
  FROM event_table
  GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
),
matched AS (
  SELECT
    ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE,
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
)
SELECT rids, matched_rule_ids
FROM matched;

-- For prefix-anywhere semantics use strpos(...) > 0 instead of = 1 (see goal.md).
