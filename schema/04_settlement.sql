-- =============================================================
-- 04_settlement.sql  —  Settlement Batches, Line Items, Payouts
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================
-- Settlement flow:
--   1. Captures accumulate as PENDING.
--   2. run_settlement() closes a batch: OPEN → CLOSED.
--   3. Network returns ACK file: CLOSED → RECONCILED (or DISPUTED).
--   4. Payout is scheduled → IN_TRANSIT → CREDITED to merchant bank.
-- =============================================================

-- ---------------------------------------------------------------
-- Settlement Batches
-- A batch groups captures for a merchant for one settlement cycle.
-- ---------------------------------------------------------------
CREATE TABLE settlement_batches (
    batch_id            UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),

    status              batch_status    NOT NULL DEFAULT 'OPEN',
    batch_date          DATE            NOT NULL,           -- date on which batch was closed
    cycle_start_at      TIMESTAMPTZ     NOT NULL,
    cycle_end_at        TIMESTAMPTZ,

    -- Amounts (in paise)
    gross_amount_paise  BIGINT          NOT NULL DEFAULT 0,
    total_fees_paise    BIGINT          NOT NULL DEFAULT 0,
    total_refunds_paise BIGINT          NOT NULL DEFAULT 0,
    net_payable_paise   BIGINT          GENERATED ALWAYS AS
                            (gross_amount_paise - total_fees_paise - total_refunds_paise) STORED,

    -- Network file reference (from Visa/MC/RuPay settlement file)
    network_file_ref    VARCHAR(100)    UNIQUE,
    network_settled_at  TIMESTAMPTZ,

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    closed_at           TIMESTAMPTZ,

    CONSTRAINT batch_unique_merchant_date UNIQUE (merchant_id, batch_date),
    CONSTRAINT batch_amounts_non_negative CHECK (
        gross_amount_paise >= 0
        AND total_fees_paise >= 0
        AND total_refunds_paise >= 0
    )
);

-- Now add the FK from captures to settlement_batches
ALTER TABLE captures
    ADD CONSTRAINT fk_captures_batch
    FOREIGN KEY (settlement_batch_id)
    REFERENCES settlement_batches(batch_id);

-- ---------------------------------------------------------------
-- Settlement Line Items
-- One row per capture (or refund) inside a batch.
-- ---------------------------------------------------------------
CREATE TABLE settlement_line_items (
    line_item_id        UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id            UUID            NOT NULL REFERENCES settlement_batches(batch_id),
    capture_id          UUID            REFERENCES captures(capture_id),
    refund_id           UUID            REFERENCES refunds(refund_id),

    -- Exactly one of capture_id or refund_id must be set
    CONSTRAINT line_item_single_source CHECK (
        (capture_id IS NOT NULL AND refund_id IS NULL)
        OR (capture_id IS NULL AND refund_id IS NOT NULL)
    ),

    line_type           VARCHAR(20)     NOT NULL    -- 'CREDIT' | 'DEBIT'
        CHECK (line_type IN ('CREDIT', 'DEBIT')),

    gross_amount_paise  BIGINT          NOT NULL,
    fee_amount_paise    BIGINT          NOT NULL DEFAULT 0,
    net_amount_paise    BIGINT          NOT NULL,

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_line_items_batch ON settlement_line_items (batch_id);

-- ---------------------------------------------------------------
-- Payouts
-- A payout is the actual NEFT/IMPS credit to the merchant's bank.
-- One payout corresponds to one reconciled settlement batch.
-- ---------------------------------------------------------------
CREATE TABLE payouts (
    payout_id           UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id            UUID            NOT NULL UNIQUE REFERENCES settlement_batches(batch_id),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),
    bank_account_id     UUID            NOT NULL REFERENCES merchant_bank_accounts(account_id),

    amount_paise        BIGINT          NOT NULL CHECK (amount_paise > 0),
    status              payout_status   NOT NULL DEFAULT 'SCHEDULED',

    scheduled_for       DATE            NOT NULL,           -- T+N date
    initiated_at        TIMESTAMPTZ,
    credited_at         TIMESTAMPTZ,
    failed_at           TIMESTAMPTZ,
    failure_reason      VARCHAR(500),

    -- Bank transaction reference
    utr_number          VARCHAR(22)     UNIQUE,             -- Unique Transaction Reference (NEFT/IMPS)
    bank_reference      VARCHAR(50),

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_payouts_merchant_scheduled
    ON payouts (merchant_id, scheduled_for DESC);

-- Partial index: pending payouts are the hot path for operations dashboards
CREATE INDEX idx_payouts_pending
    ON payouts (scheduled_for, merchant_id)
    WHERE status IN ('SCHEDULED', 'IN_TRANSIT');

COMMENT ON TABLE payouts IS
    'Actual bank credits to merchant accounts. One payout per reconciled settlement batch.';
COMMENT ON COLUMN payouts.utr_number IS
    'Unique Transaction Reference — the NEFT/IMPS reference that appears in merchant bank statement.';

-- ---------------------------------------------------------------
-- Reconciliation Mismatches
-- When network settlement file amounts differ from our records.
-- ---------------------------------------------------------------
CREATE TABLE reconciliation_mismatches (
    mismatch_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id            UUID            NOT NULL REFERENCES settlement_batches(batch_id),
    capture_id          UUID            REFERENCES captures(capture_id),
    rrn                 VARCHAR(30),

    our_amount_paise    BIGINT          NOT NULL,
    network_amount_paise BIGINT         NOT NULL,
    delta_paise         BIGINT          GENERATED ALWAYS AS
                            (network_amount_paise - our_amount_paise) STORED,

    mismatch_type       VARCHAR(50)     NOT NULL
        CHECK (mismatch_type IN ('AMOUNT_MISMATCH', 'MISSING_IN_NETWORK', 'EXTRA_IN_NETWORK', 'DUPLICATE')),

    detected_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    resolved_at         TIMESTAMPTZ,
    resolution_note     TEXT
);

CREATE INDEX idx_mismatches_batch ON reconciliation_mismatches (batch_id)
    WHERE resolved_at IS NULL;
