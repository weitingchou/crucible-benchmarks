-- V3 — Dedup + carry RIDs via array_agg (single scan of event_table).
-- Primary output is the COMPACT grouped form: one row per matched tuple, two arrays.
-- This avoids ever materializing 9.3M output rows.
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
  SELECT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE,
         array_agg(RID) AS rids
  FROM event_table
  GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
),
matched AS (
  SELECT
    ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE,
    arbitrary(ed.rids)   AS rids,             -- rids identical within a group -> pick one
    array_agg(R.RULE_ID) AS matched_rule_ids  -- aggregate per tuple BEFORE any explode
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
SELECT rids, matched_rule_ids
FROM matched;

-- If the consumer needs one row per event instead, explode at the very end:
--   SELECT rid, matched_rule_ids
--   FROM matched CROSS JOIN UNNEST(rids) AS t(rid);
