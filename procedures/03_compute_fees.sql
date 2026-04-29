-- =============================================================
-- 03_compute_fees.sql  —  MDR + Interchange Fee Calculator
-- =============================================================
-- compute_capture_fee(p_capture_id)
--
-- Looks up the active fee_config for the capture's merchant,
-- payment_method, and card_network, then:
--   1. Calculates MDR fee in paise
--   2. Applies flat fee
--   3. Updates the capture row with fee breakdown
--
-- Called by the application layer immediately after a capture
-- is created, before it enters settlement.
-- =============================================================

CREATE OR REPLACE FUNCTION compute_capture_fee(p_capture_id UUID)
RETURNS TABLE (
    capture_id          UUID,
    capture_amount_paise BIGINT,
    mdr_bps_applied     INT,
    fee_amount_paise    BIGINT,
    net_amount_paise    BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_merchant_id       UUID;
    v_payment_method    payment_method;
    v_card_network      card_network;
    v_amount_paise      BIGINT;
    v_mdr_bps           INT := 0;
    v_interchange_bps   INT := 0;
    v_flat_fee_paise    INT := 0;
    v_fee_paise         BIGINT;
BEGIN
    -- Fetch capture details
    SELECT c.merchant_id,
           a.payment_method,
           a.card_network,
           c.capture_amount_paise
    INTO   v_merchant_id, v_payment_method, v_card_network, v_amount_paise
    FROM   captures c
    JOIN   authorizations a ON a.auth_id = c.auth_id
    WHERE  c.capture_id = p_capture_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Capture % not found', p_capture_id
            USING ERRCODE = 'P0002';
    END IF;

    -- Look up active fee config (most specific match wins)
    -- Priority: merchant + method + network > merchant + method > default
    SELECT fc.mdr_bps, fc.interchange_bps, fc.flat_fee_paise
    INTO   v_mdr_bps, v_interchange_bps, v_flat_fee_paise
    FROM   fee_config fc
    WHERE  fc.merchant_id    = v_merchant_id
      AND  fc.payment_method = v_payment_method
      AND  (fc.card_network   = v_card_network OR fc.card_network IS NULL)
      AND  fc.effective_from <= CURRENT_DATE
      AND  (fc.effective_to IS NULL OR fc.effective_to >= CURRENT_DATE)
    ORDER  BY
        -- More specific (network set) wins over generic (network NULL)
        (fc.card_network IS NOT NULL) DESC,
        fc.effective_from DESC
    LIMIT  1;

    -- If no config found, apply a default 2% MDR
    IF NOT FOUND THEN
        v_mdr_bps         := 200;
        v_interchange_bps := 0;
        v_flat_fee_paise  := 0;
        RAISE WARNING
            'No fee_config found for merchant % / % / %. Applying default 200 bps.',
            v_merchant_id, v_payment_method, v_card_network;
    END IF;

    -- Calculate fee
    -- Formula: fee = CEIL(amount × (mdr_bps + interchange_bps) / 10000) + flat_fee
    v_fee_paise := CEIL(v_amount_paise::NUMERIC
                        * (v_mdr_bps + v_interchange_bps)
                        / 10000.0)
                   + v_flat_fee_paise;

    -- Update capture
    UPDATE captures c
    SET    mdr_bps_applied = v_mdr_bps,
           fee_amount_paise = v_fee_paise
    WHERE  c.capture_id = p_capture_id;

    -- Return fee breakdown
    RETURN QUERY
    SELECT p_capture_id,
           v_amount_paise,
           v_mdr_bps,
           v_fee_paise,
           v_amount_paise - v_fee_paise;
END;
$$;

COMMENT ON FUNCTION compute_capture_fee(UUID) IS
    'Looks up active MDR config for a capture, computes fee in paise, updates the capture row. '
    'Uses specificity-ordered config lookup: network-specific beats generic. '
    'Falls back to 200 bps default if no config found.';

-- -----------------------------------------------------------
-- Helper: preview fee for a hypothetical transaction
-- (does NOT write anything — useful for quoting APIs)
-- -----------------------------------------------------------
CREATE OR REPLACE FUNCTION preview_fee(
    p_merchant_id    UUID,
    p_payment_method payment_method,
    p_card_network   card_network,
    p_amount_paise   BIGINT
)
RETURNS TABLE (
    mdr_bps          INT,
    interchange_bps  INT,
    flat_fee_paise   INT,
    fee_amount_paise BIGINT,
    net_amount_paise BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_mdr_bps           INT;
    v_interchange_bps   INT;
    v_flat_fee_paise    INT;
    v_fee_paise         BIGINT;
BEGIN
    SELECT fc.mdr_bps, fc.interchange_bps, fc.flat_fee_paise
    INTO   v_mdr_bps, v_interchange_bps, v_flat_fee_paise
    FROM   fee_config fc
    WHERE  fc.merchant_id    = p_merchant_id
      AND  fc.payment_method = p_payment_method
      AND  (fc.card_network   = p_card_network OR fc.card_network IS NULL)
      AND  fc.effective_from <= CURRENT_DATE
      AND  (fc.effective_to IS NULL OR fc.effective_to >= CURRENT_DATE)
    ORDER  BY (fc.card_network IS NOT NULL) DESC, fc.effective_from DESC
    LIMIT  1;

    v_mdr_bps         := COALESCE(v_mdr_bps,         200);
    v_interchange_bps := COALESCE(v_interchange_bps,  0);
    v_flat_fee_paise  := COALESCE(v_flat_fee_paise,   0);

    v_fee_paise := CEIL(p_amount_paise::NUMERIC
                        * (v_mdr_bps + v_interchange_bps)
                        / 10000.0)
                   + v_flat_fee_paise;

    RETURN QUERY
    SELECT v_mdr_bps, v_interchange_bps, v_flat_fee_paise,
           v_fee_paise, p_amount_paise - v_fee_paise;
END;
$$;
