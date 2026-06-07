-- V2 — Dedup events to distinct dimension tuples (lever A), hash-join the verdict
-- back to recover RIDs. Reads event_table TWICE (dedup + join-back).
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
),
event_dims AS (
  SELECT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
  FROM event_table
  GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
),
matched_dims AS (
  SELECT
    ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE,
    array_agg(R.RULE_ID) AS matched_rule_ids
  FROM event_dims ed
  JOIN rules R
    ON (R.OPE_NO  IS NULL OR ed.OPE_NO    LIKE R.OPE_NO)
   AND (R.PD_ID   IS NULL OR ed.PD_ID     LIKE R.PD_ID  ESCAPE '$')
   AND (R.PRODUCT IS NULL OR ed.PART      LIKE R.product_pat)
   AND (R.STAGE   IS NULL OR ed.STAGE     LIKE R.STAGE  ESCAPE '$')
   AND (R.ROUTE   IS NULL OR ed.MAINPD_ID LIKE R.ROUTE  ESCAPE '$')
   AND (R.sub_lot_arr IS NULL OR contains(R.sub_lot_arr, ed.SUB_LOT_TYPE))
  GROUP BY ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE
)
SELECT E.RID, m.matched_rule_ids
FROM event_table E
JOIN matched_dims m
  ON  E.PART         IS NOT DISTINCT FROM m.PART
  AND E.MAINPD_ID    IS NOT DISTINCT FROM m.MAINPD_ID
  AND E.STAGE        IS NOT DISTINCT FROM m.STAGE
  AND E.OPE_NO       IS NOT DISTINCT FROM m.OPE_NO
  AND E.PD_ID        IS NOT DISTINCT FROM m.PD_ID
  AND E.SUB_LOT_TYPE IS NOT DISTINCT FROM m.SUB_LOT_TYPE;
