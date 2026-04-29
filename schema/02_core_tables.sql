-- =============================================================
-- 02_core_tables.sql  —  Merchants, Terminals, Bank Accounts
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================

-- ---------------------------------------------------------------
-- Merchants
-- A merchant is a business entity that accepts payments.
-- One merchant can have many terminals and bank accounts.
-- ---------------------------------------------------------------
CREATE TABLE merchants (
    merchant_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_name          VARCHAR(200)    NOT NULL,
    display_name        VARCHAR(200)    NOT NULL,
    category            merchant_category NOT NULL,
    mcc_code            CHAR(4)         NOT NULL,           -- ISO 18245 MCC
    gstin               CHAR(15),                           -- Indian GST number
    pan                 CHAR(10),                           -- Permanent Account Number
    onboarded_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    chargeback_ratio_threshold NUMERIC(5,2) NOT NULL DEFAULT 1.00, -- in %

    -- Settlement cycle: how often merchant gets paid
    settlement_cycle_days INT          NOT NULL DEFAULT 2    -- T+2 by default
        CHECK (settlement_cycle_days BETWEEN 1 AND 7),

    CONSTRAINT merchants_gstin_format CHECK (
        gstin IS NULL OR gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$'
    )
);

COMMENT ON TABLE merchants IS
    'Core merchant registry. Each row is a business entity onboarded to accept payments.';
COMMENT ON COLUMN merchants.settlement_cycle_days IS
    'T+N settlement: 1 = next-day, 2 = standard T+2, etc.';

-- ---------------------------------------------------------------
-- Merchant Bank Accounts
-- Multiple accounts allowed; exactly one must be PRIMARY at a time.
-- ---------------------------------------------------------------
CREATE TABLE merchant_bank_accounts (
    account_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),
    bank_name           VARCHAR(100)    NOT NULL,
    ifsc_code           CHAR(11)        NOT NULL,
    account_number      VARCHAR(20)     NOT NULL,
    account_holder_name VARCHAR(200)    NOT NULL,
    is_primary          BOOLEAN         NOT NULL DEFAULT FALSE,
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ifsc_format CHECK (ifsc_code ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
    CONSTRAINT unique_primary_per_merchant UNIQUE (merchant_id, is_primary)
        DEFERRABLE INITIALLY DEFERRED   -- allows atomic swap of primary account
);

COMMENT ON CONSTRAINT unique_primary_per_merchant ON merchant_bank_accounts IS
    'Only one primary account per merchant. DEFERRABLE so swap can be done in one transaction.';

-- ---------------------------------------------------------------
-- Terminals
-- A terminal is a physical or virtual acceptance point.
-- It belongs to exactly one merchant.
-- ---------------------------------------------------------------
CREATE TABLE terminals (
    terminal_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),
    terminal_type       terminal_type   NOT NULL,
    serial_number       VARCHAR(50)     UNIQUE,             -- NULL for ECOM/QR
    location_label      VARCHAR(200),                       -- "Store #3 - Ground Floor"
    city                VARCHAR(100),
    state               VARCHAR(100),
    pincode             CHAR(6),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    deployed_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    last_txn_at         TIMESTAMPTZ,

    CONSTRAINT pincode_format CHECK (pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$')
);

COMMENT ON TABLE terminals IS
    'Physical or virtual payment acceptance devices. ECOM terminals represent payment gateway integrations.';

-- ---------------------------------------------------------------
-- MDR (Merchant Discount Rate) Fee Configuration
-- Stores the fee tiers applied to transactions.
-- A merchant+method+network combination maps to a fee row.
-- ---------------------------------------------------------------
CREATE TABLE fee_config (
    fee_config_id       UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id         UUID            NOT NULL REFERENCES merchants(merchant_id),
    payment_method      payment_method  NOT NULL,
    card_network        card_network,                       -- NULL for non-card methods
    mdr_bps             INT             NOT NULL            -- basis points (100 bps = 1%)
        CHECK (mdr_bps BETWEEN 0 AND 500),
    interchange_bps     INT             NOT NULL DEFAULT 0
        CHECK (interchange_bps BETWEEN 0 AND 300),
    flat_fee_paise      INT             NOT NULL DEFAULT 0  -- flat fee in paise (₹0.01)
        CHECK (flat_fee_paise >= 0),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,                               -- NULL = currently active

    CONSTRAINT fee_config_date_order CHECK (
        effective_to IS NULL OR effective_to > effective_from
    )
);

COMMENT ON COLUMN fee_config.mdr_bps IS
    'Merchant Discount Rate in basis points. Applied on transaction amount.';
COMMENT ON COLUMN fee_config.interchange_bps IS
    'Interchange component (passed through from card network) in basis points.';
