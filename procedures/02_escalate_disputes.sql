-- =============================================================
-- 02_escalate_disputes.sql  —  Auto-Escalate Stale Disputes
-- =============================================================
-- escalate_overdue_disputes()
-- Moves disputes past their response_due_by date from
-- UNDER_REVIEW → ARBITRATION and assigns a system note.
-- Designed to run as a daily cron / pg_cron job.
-- =============================================================

CREATE OR REPLACE FUNCTION escalate_overdue_disputes()
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT := 0;
    v_dispute RECORD;
BEGIN
    FOR v_dispute IN
        SELECT dispute_id, cb_reference, merchant_id, response_due_by
        FROM   disputes
        WHERE  status          IN ('UNDER_REVIEW', 'EVIDENCE_SUBMITTED')
          AND  response_due_by  < CURRENT_DATE
          AND  resolved_at     IS NULL
        FOR UPDATE SKIP LOCKED
    LOOP
        -- FSM trigger (02_dispute_fsm.sql) will validate this transition
        UPDATE disputes
        SET    status       = 'ARBITRATION',
               outcome_note = FORMAT(
                   'Auto-escalated to ARBITRATION on %s: response deadline %s was missed.',
                   CURRENT_DATE, v_dispute.response_due_by
               ),
               assigned_to  = 'SYSTEM_ESCALATION'
        WHERE  dispute_id = v_dispute.dispute_id;

        RAISE NOTICE 'Escalated dispute % (merchant %) — deadline was %',
            v_dispute.cb_reference, v_dispute.merchant_id, v_dispute.response_due_by;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION escalate_overdue_disputes() IS
    'Auto-escalates stale disputes to ARBITRATION. Idempotent: SKIP LOCKED prevents '
    'double-processing if run concurrently. Returns count of escalated disputes.';
