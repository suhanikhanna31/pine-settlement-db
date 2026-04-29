-- =============================================================
-- 01_enums.sql  —  Domain Enums
-- MerchantLens: Merchant Settlement & Analytics Database
-- =============================================================

-- Payment network / method used for the transaction
CREATE TYPE payment_method AS ENUM (
    'CREDIT_CARD',
    'DEBIT_CARD',
    'UPI',
    'WALLET',
    'NET_BANKING',
    'EMI',
    'BNPL'          -- Buy-Now-Pay-Later
);

-- Card network (NULL for non-card methods)
CREATE TYPE card_network AS ENUM (
    'VISA',
    'MASTERCARD',
    'RUPAY',
    'AMEX',
    'DINERS'
);

-- Lifecycle of a payment authorization
CREATE TYPE auth_status AS ENUM (
    'INITIATED',
    'AUTHORISED',
    'PARTIALLY_CAPTURED',
    'FULLY_CAPTURED',
    'VOIDED',
    'EXPIRED'
);

-- Capture (actual money movement) status
CREATE TYPE capture_status AS ENUM (
    'PENDING',
    'SUBMITTED',
    'SETTLED',
    'FAILED',
    'REFUNDED'
);

-- Refund status
CREATE TYPE refund_status AS ENUM (
    'REQUESTED',
    'PROCESSING',
    'COMPLETED',
    'REJECTED'
);

-- Settlement batch status
CREATE TYPE batch_status AS ENUM (
    'OPEN',         -- accumulating line items
    'CLOSED',       -- no new items; sent to network
    'RECONCILED',   -- network ACK received; amounts confirmed
    'DISPUTED'      -- mismatch found; under investigation
);

-- Payout status (merchant bank credit)
CREATE TYPE payout_status AS ENUM (
    'SCHEDULED',
    'IN_TRANSIT',
    'CREDITED',
    'FAILED',
    'ON_HOLD'       -- compliance/fraud hold
);

-- Chargeback / dispute state machine
-- Valid transitions enforced by trigger (see triggers/02_dispute_fsm.sql)
CREATE TYPE dispute_status AS ENUM (
    'RECEIVED',         -- bank files chargeback
    'UNDER_REVIEW',     -- ops team reviewing evidence
    'EVIDENCE_SUBMITTED',
    'WON',              -- merchant wins; funds reversed back
    'LOST',             -- merchant loses; funds go to cardholder
    'ARBITRATION',      -- escalated to card network
    'WITHDRAWN'         -- cardholder withdrew dispute
);

-- Dispute reason codes (ISO 8583 / Visa/MC reason codes mapped to human names)
CREATE TYPE dispute_reason AS ENUM (
    'FRAUDULENT_TRANSACTION',
    'ITEM_NOT_RECEIVED',
    'ITEM_NOT_AS_DESCRIBED',
    'DUPLICATE_PROCESSING',
    'CREDIT_NOT_PROCESSED',
    'SUBSCRIPTION_CANCELLED',
    'UNRECOGNISED_TRANSACTION',
    'PROCESSING_ERROR'
);

-- Audit log operation type
CREATE TYPE audit_operation AS ENUM ('INSERT', 'UPDATE', 'DELETE');

-- Merchant category (MCC group)
CREATE TYPE merchant_category AS ENUM (
    'RETAIL',
    'FOOD_AND_BEVERAGE',
    'TRAVEL',
    'HEALTHCARE',
    'EDUCATION',
    'FUEL',
    'UTILITIES',
    'ECOMMERCE',
    'OTHER'
);

-- Terminal type
CREATE TYPE terminal_type AS ENUM (
    'POS',          -- physical point-of-sale
    'MPOS',         -- mobile POS (Pine Labs Plutus etc.)
    'ECOM',         -- online / payment gateway
    'QR',           -- QR-based acceptance
    'TAP_ON_PHONE'  -- SoftPOS
);
