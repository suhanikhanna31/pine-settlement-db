-- =============================================================
-- 03_top_merchants.sql  —  Window Function Ranking Queries
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================

-- -----------------------------------------------------------
-- Q1: Top 10 merchants by GMV this month with rank and
--     month-over-month growth (window functions showcase)
-- -----------------------------------------------------------
WITH monthly_gmv AS (
    SELECT
        c.merchant_id,
        DATE_TRUNC('month', c.captured_at)          AS month,
        SUM(c.capture_amount_paise)                 AS gmv_paise,
        COUNT(c.capture_id)                         AS txn_count
    FROM captures c
    WHERE c.status NOT IN ('FAILED')
      AND c.captured_at >= NOW() - INTERVAL '3 months'
    GROUP BY c.merchant_id, DATE_TRUNC('month', c.captured_at)
),
with_growth AS (
    SELECT
        mg.merchant_id,
        mg.month,
        mg.gmv_paise,
        mg.txn_count,
        LAG(mg.gmv_paise) OVER (
            PARTITION BY mg.merchant_id
            ORDER BY mg.month
        )                                           AS prev_month_gmv_paise,
        RANK() OVER (
            PARTITION BY mg.month
            ORDER BY mg.gmv_paise DESC
        )                                           AS gmv_rank
    FROM monthly_gmv mg
)
SELECT
    m.display_name                                  AS merchant_name,
    m.category,
    TO_CHAR(wg.month, 'Mon YYYY')                   AS month,
    wg.gmv_rank,
    ROUND(wg.gmv_paise / 100.0, 2)                  AS gmv_inr,
    wg.txn_count,
    ROUND(wg.gmv_paise / 100.0 / NULLIF(wg.txn_count, 0), 2)
                                                    AS avg_ticket_inr,
    ROUND(
        100.0 * (wg.gmv_paise - wg.prev_month_gmv_paise)
        / NULLIF(wg.prev_month_gmv_paise, 0),
        1
    )                                               AS mom_growth_pct
FROM with_growth wg
JOIN merchants m ON m.merchant_id = wg.merchant_id
WHERE wg.month = DATE_TRUNC('month', NOW())
  AND wg.gmv_rank <= 10
ORDER BY wg.gmv_rank;


-- -----------------------------------------------------------
-- Q2: Running cumulative GMV per day for current month
--     (useful for revenue pacing dashboards)
-- -----------------------------------------------------------
WITH daily_gmv AS (
    SELECT
        DATE(c.captured_at AT TIME ZONE 'Asia/Kolkata')     AS capture_date,
        SUM(c.capture_amount_paise)                         AS daily_paise
    FROM captures c
    WHERE c.status NOT IN ('FAILED')
      AND c.captured_at >= DATE_TRUNC('month', NOW())
    GROUP BY capture_date
)
SELECT
    capture_date,
    ROUND(daily_paise / 100.0, 2)                           AS daily_gmv_inr,
    ROUND(SUM(daily_paise) OVER (
        ORDER BY capture_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / 100.0, 2)                                           AS cumulative_gmv_inr,
    ROUND(AVG(daily_paise) OVER (
        ORDER BY capture_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) / 100.0, 2)                                           AS rolling_7d_avg_inr
FROM daily_gmv
ORDER BY capture_date;


-- -----------------------------------------------------------
-- Q3: Terminal performance: percentile rank within merchant
-- -----------------------------------------------------------
SELECT
    t.terminal_id,
    t.location_label,
    t.terminal_type,
    m.display_name                                          AS merchant_name,
    COUNT(c.capture_id)                                     AS txn_count,
    ROUND(SUM(c.capture_amount_paise) / 100.0, 2)          AS gmv_inr,
    PERCENT_RANK() OVER (
        PARTITION BY t.merchant_id
        ORDER BY SUM(c.capture_amount_paise)
    )                                                       AS gmv_percentile_within_merchant,
    NTILE(4) OVER (
        PARTITION BY t.merchant_id
        ORDER BY SUM(c.capture_amount_paise)
    )                                                       AS gmv_quartile        -- 1=bottom, 4=top
FROM terminals t
JOIN authorizations a  ON a.terminal_id = t.terminal_id
JOIN captures c        ON c.auth_id     = a.auth_id
JOIN merchants m       ON m.merchant_id = t.merchant_id
WHERE c.captured_at >= NOW() - INTERVAL '30 days'
  AND c.status NOT IN ('FAILED')
GROUP BY t.terminal_id, t.location_label, t.terminal_type, t.merchant_id, m.display_name
ORDER BY t.merchant_id, gmv_inr DESC;


-- =============================================================
-- 04_cohort_analysis.sql  —  Monthly GMV Cohort Analysis
-- =============================================================
-- Merchants are grouped by their onboarding month (cohort).
-- For each subsequent month, we track what fraction of the
-- cohort's original GMV is still being generated.
-- This reveals merchant retention and ramp-up patterns.
-- =============================================================

WITH merchant_cohorts AS (
    SELECT
        merchant_id,
        DATE_TRUNC('month', onboarded_at)               AS cohort_month
    FROM merchants
    WHERE is_active = TRUE
),
monthly_gmv AS (
    SELECT
        c.merchant_id,
        DATE_TRUNC('month', c.captured_at)              AS activity_month,
        SUM(c.capture_amount_paise)                     AS gmv_paise
    FROM captures c
    WHERE c.status NOT IN ('FAILED')
    GROUP BY c.merchant_id, activity_month
),
cohort_gmv AS (
    SELECT
        mc.cohort_month,
        mg.activity_month,
        -- Months since onboarding
        EXTRACT(YEAR FROM AGE(mg.activity_month, mc.cohort_month)) * 12
        + EXTRACT(MONTH FROM AGE(mg.activity_month, mc.cohort_month)) AS months_since_onboarding,
        COUNT(DISTINCT mc.merchant_id)                  AS active_merchants,
        SUM(mg.gmv_paise)                               AS cohort_gmv_paise
    FROM merchant_cohorts mc
    JOIN monthly_gmv mg ON mg.merchant_id = mc.merchant_id
                        AND mg.activity_month >= mc.cohort_month
    GROUP BY mc.cohort_month, mg.activity_month
),
cohort_baseline AS (
    SELECT
        cohort_month,
        cohort_gmv_paise                                AS baseline_gmv_paise,
        active_merchants                                AS baseline_merchants
    FROM cohort_gmv
    WHERE months_since_onboarding = 0
)
SELECT
    TO_CHAR(cg.cohort_month, 'Mon YYYY')                AS cohort,
    cg.months_since_onboarding,
    cg.active_merchants,
    ROUND(cg.cohort_gmv_paise / 100.0, 2)               AS cohort_gmv_inr,
    ROUND(
        100.0 * cg.cohort_gmv_paise
        / NULLIF(cb.baseline_gmv_paise, 0),
        1
    )                                                   AS gmv_retention_pct
FROM cohort_gmv cg
JOIN cohort_baseline cb ON cb.cohort_month = cg.cohort_month
WHERE cg.cohort_month >= NOW() - INTERVAL '12 months'
ORDER BY cg.cohort_month, cg.months_since_onboarding;
