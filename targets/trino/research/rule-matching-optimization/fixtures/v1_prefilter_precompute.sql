-- V1 — Cheaper per pair (lever B), still a cross join (nested loop).
--   * rule-only OR block pulled into a pre-filter and simplified
--   * PRODUCT||PRODUCT_2 concat and split(SUB_LOT_TYPE) precomputed once per rule
--   * predicates ordered most-selective-first so AND short-circuits
-- Run with:  USE iceberg.rule_match;
WITH rules AS (
  SELECT
    RULE_ID,
    PRODUCT,
    PRODUCT || COALESCE(PRODUCT_2, '')                     AS product_pat,
    ROUTE, STAGE, OPE_NO, PD_ID,
    CASE WHEN SUB_LOT_TYPE IS NULL THEN NULL
         ELSE split(SUB_LOT_TYPE, ',') END                 AS sub_lot_arr
  FROM rule_table
  WHERE NOT (P_TYPE_LIST IS NULL AND D_LIST IS NULL AND MEM_VERSION_LIST IS NOT NULL)
)
SELECT
  E.RID,
  array_agg(R.RULE_ID) AS matched_rule_ids
FROM rules R
CROSS JOIN event_table E
-- ordering: tune from diagnostics.sql (set fractions / cardinalities)
WHERE (R.OPE_NO  IS NULL OR E.OPE_NO    LIKE R.OPE_NO)
  AND (R.PD_ID   IS NULL OR E.PD_ID     LIKE R.PD_ID  ESCAPE '$')
  AND (R.PRODUCT IS NULL OR E.PART      LIKE R.product_pat)
  AND (R.STAGE   IS NULL OR E.STAGE     LIKE R.STAGE  ESCAPE '$')
  AND (R.ROUTE   IS NULL OR E.MAINPD_ID LIKE R.ROUTE  ESCAPE '$')
  AND (R.sub_lot_arr IS NULL OR contains(R.sub_lot_arr, E.SUB_LOT_TYPE))
GROUP BY E.RID;
