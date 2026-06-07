-- V5 — (OPTIONAL / ADVANCED) Escape the nested loop for simple PRODUCT prefixes.
-- Simple `literal%` PRODUCT rules become a real HASH JOIN on substr(PART, 1, len);
-- everything else stays a nested loop. UNION ALL the two paths, then aggregate.
--
-- This dataset's simple PRODUCT literals all have length 4 ('Pxxx'), so a single
-- equi-join suffices. The GENERAL case (literals of several lengths) needs one
-- equi-join per distinct length, UNION ALL-ed -- Trino cannot hash-join on a
-- probe-side substr() whose length comes from the build side.
-- Run with:  USE iceberg.rule_match;
WITH rules AS (
  SELECT
    RULE_ID, PRODUCT, ROUTE, STAGE, OPE_NO, PD_ID,
    PRODUCT || COALESCE(PRODUCT_2, '')                                            AS product_pat,
    CASE WHEN SUB_LOT_TYPE IS NULL THEN NULL ELSE split(SUB_LOT_TYPE, ',') END    AS sub_lot_arr,
    (PRODUCT || COALESCE(PRODUCT_2, '')) LIKE '%\%' ESCAPE '\'
      AND NOT regexp_like(
            substr(PRODUCT || COALESCE(PRODUCT_2, ''), 1,
                   length(PRODUCT || COALESCE(PRODUCT_2, '')) - 1), '[%_]')        AS product_simple,
    substr(PRODUCT || COALESCE(PRODUCT_2, ''), 1,
           length(PRODUCT || COALESCE(PRODUCT_2, '')) - 1)                         AS product_literal
  FROM rule_table
  WHERE NOT (P_TYPE_LIST IS NULL AND D_LIST IS NULL AND MEM_VERSION_LIST IS NOT NULL)
),
event_dims AS (
  SELECT PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE,
         array_agg(RID) AS rids
  FROM event_table
  GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE
),
-- Path A: simple length-4 PRODUCT prefix -> hash join (dynamic filtering kicks in)
path_a AS (
  SELECT
    ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE, ed.rids,
    R.RULE_ID
  FROM event_dims ed
  JOIN rules R
    ON substr(ed.PART, 1, 4) = R.product_literal
   AND R.product_simple
   AND length(R.product_literal) = 4
   AND (R.OPE_NO IS NULL OR ed.OPE_NO    LIKE R.OPE_NO)
   AND (R.PD_ID  IS NULL OR ed.PD_ID     LIKE R.PD_ID  ESCAPE '$')
   AND (R.STAGE  IS NULL OR ed.STAGE     LIKE R.STAGE  ESCAPE '$')
   AND (R.ROUTE  IS NULL OR ed.MAINPD_ID LIKE R.ROUTE  ESCAPE '$')
   AND (R.sub_lot_arr IS NULL OR contains(R.sub_lot_arr, ed.SUB_LOT_TYPE))
),
-- Path B: PRODUCT NULL or non-simple (or other-length) pattern -> nested loop
path_b AS (
  SELECT
    ed.PART, ed.MAINPD_ID, ed.STAGE, ed.OPE_NO, ed.PD_ID, ed.SUB_LOT_TYPE, ed.rids,
    R.RULE_ID
  FROM event_dims ed
  JOIN rules R
    ON (NOT COALESCE(R.product_simple, false) OR length(R.product_literal) <> 4)
   AND (R.PRODUCT IS NULL OR ed.PART LIKE R.product_pat)
   AND (R.OPE_NO  IS NULL OR ed.OPE_NO    LIKE R.OPE_NO)
   AND (R.PD_ID   IS NULL OR ed.PD_ID     LIKE R.PD_ID  ESCAPE '$')
   AND (R.STAGE   IS NULL OR ed.STAGE     LIKE R.STAGE  ESCAPE '$')
   AND (R.ROUTE   IS NULL OR ed.MAINPD_ID LIKE R.ROUTE  ESCAPE '$')
   AND (R.sub_lot_arr IS NULL OR contains(R.sub_lot_arr, ed.SUB_LOT_TYPE))
),
unioned AS (
  SELECT * FROM path_a
  UNION ALL
  SELECT * FROM path_b
)
SELECT
  arbitrary(rids)      AS rids,
  array_agg(RULE_ID)   AS matched_rule_ids
FROM unioned
GROUP BY PART, MAINPD_ID, STAGE, OPE_NO, PD_ID, SUB_LOT_TYPE;
