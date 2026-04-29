-- =============================================================
-- 03_transaction.sql  —  Authorizations, Captures, Refunds
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================
-- Design note:
--   Authorization and Capture are separate tables because:
--   1. An auth can be partially captured (e.g., hotel pre-auth).
--   2. Capture amount <= auth amount; the difference is auto-voided.
--   3. Network settlement is driven by captures, not authorizations.
-- =============================================================

-- ---------------------------------------------------------------
-- Authorizations
-- An authorization reserves funds on the cardholder's account.
-- It does NOT move money; a capture does.
-- ---------------------------------------------------------------
CREATE TABLE authorizations (
    auth_id             UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    terminal_id         UUID            NOT NULL REFERENCES terminals(terminal_id),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),

    -- External reference numbers
    rrn                 VARCHAR(30)     NOT NULL UNIQUE,    -- Retrieval Reference Number (from network)
    approval_code       VARCHAR(10),                        -- issuer approval code
    acquirer_txn_id     VARCHAR(50)     UNIQUE,             -- acquirer-assigned ID

    -- Payment details
    payment_method      payment_method  NOT NULL,
    card_network        card_network,
    masked_card_number  VARCHAR(19),                        -- e.g. 4111 **** **** 1234
    card_last4          CHAR(4),
    card_expiry_month   SMALLINT        CHECK (card_expiry_month BETWEEN 1 AND 12),
    card_expiry_year    SMALLINT        CHECK (card_expiry_year BETWEEN 2020 AND 2040),

    -- Amounts (all in paise = ₹0.01 to avoid floating-point issues)
    requested_amount_paise  BIGINT      NOT NULL CHECK (requested_amount_paise > 0),
    authorised_amount_paise BIGINT      NOT NULL CHECK (authorised_amount_paise > 0),
    currency                CHAR(3)     NOT NULL DEFAULT 'INR',

    -- Status & timing
    status              auth_status     NOT NULL DEFAULT 'INITIATED',
    initiated_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    authorised_at       TIMESTAMPTZ,
    expires_at          TIMESTAMPTZ     NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),

    -- 3DS / authentication
    is_3ds_authenticated    BOOLEAN     NOT NULL DEFAULT FALSE,
    eci_code            CHAR(2),        -- Electronic Commerce Indicator

    CONSTRAINT auth_amount_sanity CHECK (
        authorised_amount_paise <= requested_amount_paise * 1.01  -- allow 1% tolerance
    )
);

CREATE INDEX idx_auth_merchant_initiated
    ON authorizations (merchant_id, initiated_at DESC);

CREATE INDEX idx_auth_terminal_date
    ON authorizations (terminal_id, initiated_at DESC);

-- Partial index: quickly find auths that can still be captured
CREATE INDEX idx_auth_capturable
    ON authorizations (merchant_id, expires_at)
    WHERE status IN ('AUTHORISED', 'PARTIALLY_CAPTURED');

COMMENT ON TABLE authorizations IS
    'Payment authorizations. Money is reserved but not moved. Captures reference this table.';
COMMENT ON COLUMN authorizations.rrn IS
    'Retrieval Reference Number — the global identifier issued by the card network.';

-- ---------------------------------------------------------------
-- Captures
-- A capture moves money from cardholder to merchant.
-- Multiple partial captures are allowed against one authorization
-- until the authorized amount is exhausted.
-- ---------------------------------------------------------------
CREATE TABLE captures (
    capture_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_id             UUID            NOT NULL REFERENCES authorizations(auth_id),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),

    capture_amount_paise    BIGINT      NOT NULL CHECK (capture_amount_paise > 0),
    status              capture_status  NOT NULL DEFAULT 'PENDING',

    captured_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    submitted_at        TIMESTAMPTZ,        -- when sent to network in a batch
    settled_at          TIMESTAMPTZ,

    -- Which settlement batch this capture ended up in
    settlement_batch_id UUID,               -- FK added after settlement table is created

    -- Computed fee snapshot at time of capture (denormalized for audit)
    mdr_bps_applied     INT             NOT NULL DEFAULT 0,
    fee_amount_paise    BIGINT          NOT NULL DEFAULT 0,
    net_amount_paise    BIGINT          GENERATED ALWAYS AS
                            (capture_amount_paise - fee_amount_paise) STORED
);

COMMENT ON TABLE captures IS
    'Each row represents actual fund movement. Partial captures are supported.';
COMMENT ON COLUMN captures.net_amount_paise IS
    'Computed: capture amount minus fees. This is what the merchant receives.';

-- ---------------------------------------------------------------
-- Refunds
-- A refund reverses a capture, partially or fully.
-- Refunds go back to the cardholder's payment instrument.
-- ---------------------------------------------------------------
CREATE TABLE refunds (
    refund_id           UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    capture_id          UUID            NOT NULL REFERENCES captures(capture_id),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),

    refund_amount_paise BIGINT          NOT NULL CHECK (refund_amount_paise > 0),
    reason              VARCHAR(500),
    status              refund_status   NOT NULL DEFAULT 'REQUESTED',

    requested_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    processed_at        TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,

    -- Reference from the payment network for the refund
    network_refund_id   VARCHAR(50)     UNIQUE,

    initiated_by        VARCHAR(100)    NOT NULL    -- 'MERCHANT' | 'SUPPORT' | 'SYSTEM'
);

-- Validate: total refunds against a capture must not exceed capture amount
-- This is enforced via the run_settlement procedure and a constraint trigger.
CREATE INDEX idx_refunds_capture ON refunds (capture_id);
CREATE INDEX idx_refunds_merchant_requested
    ON refunds (merchant_id, requested_at DESC)
    WHERE status IN ('REQUESTED', 'PROCESSING');

COMMENT ON TABLE refunds IS
    'Refunds reverse a capture. Multiple partial refunds allowed up to capture amount.';
