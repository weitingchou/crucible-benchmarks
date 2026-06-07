-- V0 — Baseline (control). Faithful CROSS JOIN with RULE_ID aggregation added.
-- Run with:  USE iceberg.rule_match;
-- WARNING: at full scale this evaluates 9.3M x 400K pairs. Set a statement timeout,
-- or run against a reduced-scale dataset.
SELECT
  E.RID,
  array_agg(R.RULE_ID) AS matched_rule_ids
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
GROUP BY E.RID;
