-- =============================================================
-- 01_reconciliation.sql  —  Settlement Reconciliation Queries
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================
-- These queries identify discrepancies between our internal
-- records and the network settlement file.
-- =============================================================

-- -----------------------------------------------------------
-- Q1: Find captures in a closed batch that were NOT reported
--     in the network settlement file (MISSING_IN_NETWORK).
--     A capture with no matching reconciliation_mismatch row
--     and status still SUBMITTED after a threshold is suspect.
-- -----------------------------------------------------------
WITH batch_summary AS (
    SELECT
        sb.batch_id,
        sb.merchant_id,
        m.display_name      AS merchant_name,
        sb.batch_date,
        sb.gross_amount_paise,
        sb.net_payable_paise,
        sb.network_file_ref,
        sb.status
    FROM settlement_batches sb
    JOIN merchants m ON m.merchant_id = sb.merchant_id
    WHERE sb.status IN ('CLOSED', 'DISPUTED')
      AND sb.network_settled_at IS NULL                 -- ACK not received yet
      AND sb.closed_at < NOW() - INTERVAL '48 hours'   -- past expected ACK window
),
unacknowledged_captures AS (
    SELECT
        bs.batch_id,
        bs.merchant_name,
        bs.batch_date,
        c.capture_id,
        a.rrn,
        c.capture_amount_paise,
        c.captured_at
    FROM batch_summary bs
    JOIN captures c ON c.settlement_batch_id = bs.batch_id
                   AND c.status = 'SUBMITTED'
    JOIN authorizations a ON a.auth_id = c.auth_id
    -- Exclude captures already logged as mismatches
    LEFT JOIN reconciliation_mismatches rm
           ON rm.capture_id = c.capture_id
          AND rm.resolved_at IS NULL
    WHERE rm.mismatch_id IS NULL
)
SELECT
    merchant_name,
    batch_date,
    COUNT(*)                                AS unacked_capture_count,
    SUM(capture_amount_paise) / 100.0       AS unacked_amount_inr,
    MIN(captured_at)                        AS oldest_capture_at
FROM unacknowledged_captures
GROUP BY merchant_name, batch_date, batch_id
ORDER BY oldest_capture_at ASC;


-- -----------------------------------------------------------
-- Q2: Tolerance-based mismatch detection.
--     Join our capture amounts against network file amounts
--     stored in reconciliation_mismatches and find those
--     where delta exceeds ₹1 (100 paise) tolerance.
-- -----------------------------------------------------------
SELECT
    rm.mismatch_id,
    m.display_name                              AS merchant_name,
    sb.batch_date,
    rm.rrn,
    rm.our_amount_paise         / 100.0         AS our_amount_inr,
    rm.network_amount_paise     / 100.0         AS network_amount_inr,
    rm.delta_paise              / 100.0         AS delta_inr,
    rm.mismatch_type,
    rm.detected_at
FROM reconciliation_mismatches rm
JOIN settlement_batches sb ON sb.batch_id = rm.batch_id
JOIN merchants m ON m.merchant_id = sb.merchant_id
WHERE rm.resolved_at IS NULL
  AND ABS(rm.delta_paise) > 100               -- more than ₹1 variance
ORDER BY ABS(rm.delta_paise) DESC;


-- -----------------------------------------------------------
-- Q3: Duplicate capture detection.
--     Same RRN appearing more than once in SUBMITTED/SETTLED
--     captures — a sign of double-processing.
-- -----------------------------------------------------------
SELECT
    a.rrn,
    a.merchant_id,
    m.display_name              AS merchant_name,
    COUNT(c.capture_id)         AS capture_count,
    SUM(c.capture_amount_paise) / 100.0 AS total_amount_inr,
    ARRAY_AGG(c.capture_id)     AS capture_ids
FROM captures c
JOIN authorizations a ON a.auth_id = c.auth_id
JOIN merchants m ON m.merchant_id = c.merchant_id
WHERE c.status IN ('SUBMITTED', 'SETTLED')
GROUP BY a.rrn, a.merchant_id, m.display_name
HAVING COUNT(c.capture_id) > 1
ORDER BY capture_count DESC, total_amount_inr DESC;


-- -----------------------------------------------------------
-- Q4: Reconciliation health summary per merchant (last 30 days)
-- -----------------------------------------------------------
WITH merchant_batches AS (
    SELECT
        m.merchant_id,
        m.display_name,
        COUNT(sb.batch_id)                          AS total_batches,
        COUNT(sb.batch_id) FILTER (WHERE sb.status = 'RECONCILED')
                                                    AS reconciled_batches,
        COUNT(sb.batch_id) FILTER (WHERE sb.status = 'DISPUTED')
                                                    AS disputed_batches,
        SUM(sb.gross_amount_paise) / 100.0          AS total_gross_inr,
        SUM(sb.net_payable_paise) / 100.0           AS total_net_inr
    FROM merchants m
    LEFT JOIN settlement_batches sb
           ON sb.merchant_id = m.merchant_id
          AND sb.batch_date >= CURRENT_DATE - 30
    WHERE m.is_active = TRUE
    GROUP BY m.merchant_id, m.display_name
),
mismatch_counts AS (
    SELECT
        sb.merchant_id,
        COUNT(rm.mismatch_id)               AS open_mismatches,
        SUM(ABS(rm.delta_paise)) / 100.0    AS total_delta_inr
    FROM reconciliation_mismatches rm
    JOIN settlement_batches sb ON sb.batch_id = rm.batch_id
    WHERE rm.resolved_at IS NULL
      AND sb.batch_date >= CURRENT_DATE - 30
    GROUP BY sb.merchant_id
)
SELECT
    mb.display_name,
    mb.total_batches,
    mb.reconciled_batches,
    mb.disputed_batches,
    ROUND(mb.total_gross_inr, 2)            AS gross_inr,
    ROUND(mb.total_net_inr, 2)              AS net_inr,
    COALESCE(mc.open_mismatches, 0)         AS open_mismatches,
    ROUND(COALESCE(mc.total_delta_inr, 0), 2) AS delta_inr,
    ROUND(
        100.0 * mb.reconciled_batches / NULLIF(mb.total_batches, 0),
        1
    )                                       AS reconciliation_rate_pct
FROM merchant_batches mb
LEFT JOIN mismatch_counts mc ON mc.merchant_id = mb.merchant_id
ORDER BY open_mismatches DESC, total_gross_inr DESC;
