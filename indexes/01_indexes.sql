-- =============================================================
-- 01_indexes.sql  —  Indexing Strategy
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================
-- Naming convention: idx_{table}_{columns_or_purpose}
-- Each index includes a comment explaining WHY it exists and
-- which query pattern it targets.
-- =============================================================

-- -----------------------------------------------------------
-- MERCHANTS
-- -----------------------------------------------------------

-- Fast merchant lookup by category (used in portfolio reports)
CREATE INDEX idx_merchants_category_active
    ON merchants (category)
    WHERE is_active = TRUE;

COMMENT ON INDEX idx_merchants_category_active IS
    'Partial index: only active merchants. Powers portfolio and MCC-segment analytics.';

-- -----------------------------------------------------------
-- TERMINALS
-- -----------------------------------------------------------

-- List all terminals for a merchant (ops dashboard, most common join)
CREATE INDEX idx_terminals_merchant_active
    ON terminals (merchant_id, is_active, deployed_at DESC);

COMMENT ON INDEX idx_terminals_merchant_active IS
    'Covers merchant → terminals join. Filtered on is_active for operational views.';

-- -----------------------------------------------------------
-- AUTHORIZATIONS
-- -----------------------------------------------------------
-- Note: Several indexes were already created inline in 03_transaction.sql.
-- This file adds supplemental and covering indexes.

-- Covering index for the authorization lookup by RRN (most common lookup)
-- The INCLUDE avoids a heap fetch for status + amount checks.
CREATE INDEX idx_auth_rrn_covering
    ON authorizations (rrn)
    INCLUDE (auth_id, status, authorised_amount_paise, merchant_id);

COMMENT ON INDEX idx_auth_rrn_covering IS
    'Covering index for RRN-based lookups (dispute matching, reconciliation). '
    'INCLUDE avoids heap fetch for common projection columns.';

-- Expression index on date part for daily GMV aggregations
CREATE INDEX idx_auth_initiated_date
    ON authorizations ( DATE(initiated_at AT TIME ZONE 'Asia/Kolkata') );

COMMENT ON INDEX idx_auth_initiated_date IS
    'Expression index on calendar date (IST) for day-level aggregation queries.';

-- -----------------------------------------------------------
-- CAPTURES
-- -----------------------------------------------------------

-- The most critical operational index: pending captures per merchant
-- Used by run_settlement() to find what needs to be batched.
CREATE INDEX idx_captures_pending_merchant
    ON captures (merchant_id, captured_at ASC)
    WHERE status = 'PENDING';

COMMENT ON INDEX idx_captures_pending_merchant IS
    'Partial index on PENDING captures. run_settlement() scans this index exclusively. '
    'Staying small (only PENDING rows) keeps it in shared_buffers.';

-- Composite index for settlement batch reconciliation queries
CREATE INDEX idx_captures_batch_status
    ON captures (settlement_batch_id, status)
    WHERE settlement_batch_id IS NOT NULL;

COMMENT ON INDEX idx_captures_batch_status IS
    'Used by reconciliation queries that scan a batch for SETTLED / FAILED captures.';

-- -----------------------------------------------------------
-- SETTLEMENT BATCHES
-- -----------------------------------------------------------

-- Merchant × date lookup (most common for settlement history pages)
CREATE INDEX idx_batches_merchant_date
    ON settlement_batches (merchant_id, batch_date DESC);

COMMENT ON INDEX idx_batches_merchant_date IS
    'Merchant settlement history: filters by merchant, orders by date.';

-- Open batches — hot for settlement worker polling
CREATE INDEX idx_batches_open
    ON settlement_batches (merchant_id, created_at)
    WHERE status = 'OPEN';

COMMENT ON INDEX idx_batches_open IS
    'Partial index on OPEN batches. Settlement worker polls this instead of full-table scan.';

-- -----------------------------------------------------------
-- DISPUTES
-- -----------------------------------------------------------
-- Note: Core dispute indexes created inline in 05_disputes.sql.

-- Chargeback ratio calculation: need COUNT by merchant per time window
CREATE INDEX idx_disputes_merchant_received_date
    ON disputes (merchant_id, DATE(received_at AT TIME ZONE 'Asia/Kolkata') DESC);

COMMENT ON INDEX idx_disputes_merchant_received_date IS
    'Date-level aggregation for chargeback ratio reports. Expression index on calendar date.';

-- Overdue disputes: response deadline passed but still open
CREATE INDEX idx_disputes_overdue
    ON disputes (response_due_by, merchant_id)
    WHERE status IN ('RECEIVED', 'UNDER_REVIEW');

COMMENT ON INDEX idx_disputes_overdue IS
    'Partial index used by the escalate_disputes procedure to find overdue disputes.';

-- -----------------------------------------------------------
-- PAYOUTS
-- -----------------------------------------------------------

-- Ops dashboard: payouts by status and scheduled date
CREATE INDEX idx_payouts_status_scheduled
    ON payouts (status, scheduled_for)
    WHERE status IN ('SCHEDULED', 'IN_TRANSIT');

COMMENT ON INDEX idx_payouts_status_scheduled IS
    'Partial index for pending payouts. Powers the payout operations dashboard.';

-- -----------------------------------------------------------
-- AUDIT LOG
-- -----------------------------------------------------------
-- Audit log is append-only and high-volume.
-- Use BRIN index for time-range scans (very cheap to maintain).

CREATE INDEX idx_audit_changed_at_brin
    ON audit_log USING BRIN (changed_at)
    WITH (pages_per_range = 128);

COMMENT ON INDEX idx_audit_changed_at_brin IS
    'BRIN index on append-only audit_log. 200× smaller than B-tree; ideal for '
    'sequential-write tables. Supports time-range queries with low overhead.';
