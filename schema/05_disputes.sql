-- =============================================================
-- 05_disputes.sql  —  Chargebacks, Evidence, Audit Log
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================

-- ---------------------------------------------------------------
-- Disputes (Chargebacks)
-- Filed by the cardholder's issuing bank against a capture.
-- State machine: RECEIVED → UNDER_REVIEW → EVIDENCE_SUBMITTED
--                → WON | LOST | ARBITRATION | WITHDRAWN
-- Transitions enforced by trigger (triggers/02_dispute_fsm.sql).
-- ---------------------------------------------------------------
CREATE TABLE disputes (
    dispute_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    capture_id          UUID            NOT NULL REFERENCES captures(capture_id),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),

    -- Network-assigned chargeback reference
    cb_reference        VARCHAR(50)     NOT NULL UNIQUE,
    reason              dispute_reason  NOT NULL,
    reason_code         VARCHAR(10),    -- raw network reason code (e.g. "4853")

    disputed_amount_paise   BIGINT      NOT NULL CHECK (disputed_amount_paise > 0),
    status              dispute_status  NOT NULL DEFAULT 'RECEIVED',

    -- Deadlines (from network)
    response_due_by     DATE            NOT NULL,
    arbitration_due_by  DATE,

    -- Outcome
    outcome_amount_paise    BIGINT,     -- how much was reversed (may be partial)
    outcome_note        TEXT,

    received_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    resolved_at         TIMESTAMPTZ,

    -- Assigned ops team member
    assigned_to         VARCHAR(100),

    CONSTRAINT dispute_outcome_requires_resolution CHECK (
        outcome_amount_paise IS NULL OR resolved_at IS NOT NULL
    )
);

CREATE INDEX idx_disputes_merchant_status
    ON disputes (merchant_id, status, received_at DESC);

-- Partial index for open disputes (ops dashboard)
CREATE INDEX idx_disputes_open
    ON disputes (response_due_by, merchant_id)
    WHERE status NOT IN ('WON', 'LOST', 'WITHDRAWN');

COMMENT ON TABLE disputes IS
    'Chargeback lifecycle. State transitions enforced by trigger, not application code.';

-- ---------------------------------------------------------------
-- Dispute Evidence
-- Documents uploaded by the merchant to contest a chargeback.
-- ---------------------------------------------------------------
CREATE TABLE dispute_evidence (
    evidence_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    dispute_id          UUID            NOT NULL REFERENCES disputes(dispute_id),
    evidence_type       VARCHAR(50)     NOT NULL
        CHECK (evidence_type IN (
            'DELIVERY_PROOF',
            'SIGNED_RECEIPT',
            'CUSTOMER_COMMUNICATION',
            'REFUND_CONFIRMATION',
            'TERMS_OF_SERVICE',
            'TRANSACTION_RECEIPT',
            'OTHER'
        )),
    file_name           VARCHAR(300)    NOT NULL,
    file_url            TEXT            NOT NULL,       -- S3 / GCS path
    file_size_bytes     BIGINT,
    uploaded_by         VARCHAR(100)    NOT NULL,
    uploaded_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    notes               TEXT
);

CREATE INDEX idx_evidence_dispute ON dispute_evidence (dispute_id);

-- ---------------------------------------------------------------
-- Audit Log
-- Every INSERT / UPDATE / DELETE on financial tables is recorded here.
-- Populated by a trigger (triggers/01_audit_trigger.sql).
-- This table is append-only; no row is ever updated or deleted.
-- ---------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id            BIGSERIAL       PRIMARY KEY,
    table_name          VARCHAR(100)    NOT NULL,
    operation           audit_operation NOT NULL,
    record_id           TEXT            NOT NULL,       -- PK of affected row (cast to TEXT)
    changed_by          TEXT            NOT NULL        -- DB role / application user
                            DEFAULT current_user,
    changed_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    old_data            JSONB,          -- NULL on INSERT
    new_data            JSONB           -- NULL on DELETE
);

-- Time-series index for audit queries
CREATE INDEX idx_audit_table_time
    ON audit_log (table_name, changed_at DESC);

CREATE INDEX idx_audit_record
    ON audit_log (table_name, record_id, changed_at DESC);

COMMENT ON TABLE audit_log IS
    'Immutable audit trail. Never update or delete rows. Populated exclusively by triggers.';
COMMENT ON COLUMN audit_log.record_id IS
    'Primary key of the affected row, cast to TEXT for uniformity across tables.';
