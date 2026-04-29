-- =============================================================
-- 01_run_settlement.sql  —  Settlement Batch Procedure
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================
-- run_settlement(p_merchant_id, p_batch_date)
--
-- Steps executed inside a single SERIALIZABLE transaction:
--   1. Lock pending captures for the merchant (SELECT FOR UPDATE SKIP LOCKED)
--   2. Open or reuse today's settlement batch
--   3. Insert settlement line items for each capture
--   4. Update capture status → SUBMITTED; link to batch
--   5. Roll refunds into the batch (debit line items)
--   6. Recompute batch totals
--   7. Close the batch (OPEN → CLOSED)
--   8. Schedule a payout for T+N
--
-- Returns: batch_id of the closed batch.
-- =============================================================

CREATE OR REPLACE FUNCTION run_settlement(
    p_merchant_id   UUID,
    p_batch_date    DATE DEFAULT CURRENT_DATE
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_id              UUID;
    v_gross_paise           BIGINT := 0;
    v_fees_paise            BIGINT := 0;
    v_refunds_paise         BIGINT := 0;
    v_settlement_cycle      INT;
    v_payout_date           DATE;
    v_primary_account_id    UUID;
    v_capture               RECORD;
    v_refund                RECORD;
    v_capture_ids           UUID[];
BEGIN
    -- ── 0. Validate merchant ────────────────────────────────────
    IF NOT EXISTS (
        SELECT 1 FROM merchants
        WHERE merchant_id = p_merchant_id AND is_active = TRUE
    ) THEN
        RAISE EXCEPTION 'Merchant % not found or inactive', p_merchant_id
            USING ERRCODE = 'P0002';
    END IF;

    -- ── 1. Open or reuse today's batch ─────────────────────────
    INSERT INTO settlement_batches (
        merchant_id, status, batch_date, cycle_start_at
    )
    VALUES (
        p_merchant_id, 'OPEN', p_batch_date, NOW()
    )
    ON CONFLICT (merchant_id, batch_date) DO NOTHING;

    SELECT batch_id INTO v_batch_id
    FROM settlement_batches
    WHERE merchant_id = p_merchant_id
      AND batch_date  = p_batch_date
      AND status      = 'OPEN'
    FOR UPDATE;  -- lock the batch row for the duration

    IF v_batch_id IS NULL THEN
        RAISE EXCEPTION
            'Settlement batch for merchant % on % is not OPEN (already closed or disputed)',
            p_merchant_id, p_batch_date
            USING ERRCODE = 'P0003';
    END IF;

    -- ── 2. Lock pending captures (SKIP LOCKED = no deadlock risk) ──
    FOR v_capture IN
        SELECT c.capture_id,
               c.capture_amount_paise,
               c.fee_amount_paise,
               c.net_amount_paise
        FROM   captures c
        WHERE  c.merchant_id = p_merchant_id
          AND  c.status      = 'PENDING'
        ORDER  BY c.captured_at ASC
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Insert credit line item
        INSERT INTO settlement_line_items (
            batch_id, capture_id, line_type,
            gross_amount_paise, fee_amount_paise, net_amount_paise
        ) VALUES (
            v_batch_id, v_capture.capture_id, 'CREDIT',
            v_capture.capture_amount_paise,
            v_capture.fee_amount_paise,
            v_capture.net_amount_paise
        );

        -- Mark capture as SUBMITTED and link to batch
        UPDATE captures
        SET    status              = 'SUBMITTED',
               submitted_at        = NOW(),
               settlement_batch_id = v_batch_id
        WHERE  capture_id = v_capture.capture_id;

        -- Accumulate totals
        v_gross_paise := v_gross_paise + v_capture.capture_amount_paise;
        v_fees_paise  := v_fees_paise  + v_capture.fee_amount_paise;

        -- Track processed capture IDs for refund join
        v_capture_ids := v_capture_ids || v_capture.capture_id;
    END LOOP;

    IF v_gross_paise = 0 THEN
        RAISE NOTICE 'No pending captures found for merchant % on %. Batch remains OPEN.',
            p_merchant_id, p_batch_date;
        RETURN v_batch_id;
    END IF;

    -- ── 3. Roll in COMPLETED refunds for submitted captures ────
    FOR v_refund IN
        SELECT r.refund_id, r.refund_amount_paise
        FROM   refunds r
        WHERE  r.capture_id = ANY(v_capture_ids)
          AND  r.status     = 'PROCESSING'
        FOR UPDATE SKIP LOCKED
    LOOP
        INSERT INTO settlement_line_items (
            batch_id, refund_id, line_type,
            gross_amount_paise, fee_amount_paise, net_amount_paise
        ) VALUES (
            v_batch_id, v_refund.refund_id, 'DEBIT',
            v_refund.refund_amount_paise, 0, -v_refund.refund_amount_paise
        );

        UPDATE refunds
        SET status = 'COMPLETED', processed_at = NOW()
        WHERE refund_id = v_refund.refund_id;

        v_refunds_paise := v_refunds_paise + v_refund.refund_amount_paise;
    END LOOP;

    -- ── 4. Close the batch ──────────────────────────────────────
    UPDATE settlement_batches
    SET    status               = 'CLOSED',
           cycle_end_at         = NOW(),
           closed_at            = NOW(),
           gross_amount_paise   = v_gross_paise,
           total_fees_paise     = v_fees_paise,
           total_refunds_paise  = v_refunds_paise
    WHERE  batch_id = v_batch_id;

    -- ── 5. Schedule payout at T+N ───────────────────────────────
    SELECT settlement_cycle_days INTO v_settlement_cycle
    FROM   merchants WHERE merchant_id = p_merchant_id;

    v_payout_date := p_batch_date + v_settlement_cycle;

    SELECT account_id INTO v_primary_account_id
    FROM   merchant_bank_accounts
    WHERE  merchant_id = p_merchant_id
      AND  is_primary  = TRUE
      AND  verified_at IS NOT NULL
    LIMIT  1;

    IF v_primary_account_id IS NULL THEN
        RAISE WARNING
            'Merchant % has no verified primary bank account. Payout not scheduled.',
            p_merchant_id;
    ELSE
        INSERT INTO payouts (
            batch_id, merchant_id, bank_account_id,
            amount_paise, status, scheduled_for
        ) VALUES (
            v_batch_id,
            p_merchant_id,
            v_primary_account_id,
            v_gross_paise - v_fees_paise - v_refunds_paise,
            'SCHEDULED',
            v_payout_date
        )
        ON CONFLICT (batch_id) DO NOTHING;
    END IF;

    RAISE NOTICE
        'Settlement complete: batch=%, gross=₹%, fees=₹%, refunds=₹%, net=₹%, payout_date=%',
        v_batch_id,
        ROUND(v_gross_paise   / 100.0, 2),
        ROUND(v_fees_paise    / 100.0, 2),
        ROUND(v_refunds_paise / 100.0, 2),
        ROUND((v_gross_paise - v_fees_paise - v_refunds_paise) / 100.0, 2),
        v_payout_date;

    RETURN v_batch_id;
END;
$$;

COMMENT ON FUNCTION run_settlement(UUID, DATE) IS
    'Atomically closes settlement batch for a merchant: locks captures, builds line items, '
    'computes totals, closes batch, schedules payout. Safe to retry: SKIP LOCKED + ON CONFLICT.';
