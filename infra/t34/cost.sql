-- Current CN calendar day vs the previous seven *calendar days*, including quiet days.
-- A missing price and a known-cost anomaly are independent alerts; neither masks the other.
WITH boundary AS (SELECT date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai' AS d),
 totals AS (SELECT count(*) FILTER (WHERE cost_cny IS NULL) AS missing,
   coalesce(sum(cost_cny) FILTER (WHERE started_at >= d),0) AS today,
   coalesce(sum(cost_cny) FILTER (WHERE started_at < d),0) AS history
   FROM ai_calls CROSS JOIN boundary WHERE started_at >= d - interval '7 days' AND started_at <= now())
SELECT 'cost_anomaly' AS status FROM totals WHERE today*7 > 2*history
UNION ALL
SELECT 'unpriced' FROM totals WHERE missing > 0
UNION ALL
SELECT 'normal' FROM totals WHERE today*7 <= 2*history AND missing = 0;
