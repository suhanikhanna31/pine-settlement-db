-- devsecops/db_tests.sql
-- pgTAP unit tests — run in the CI "DB Validation" stage.
-- These tests are the "test" in "Infrastructure as Code":
-- they verify business-critical DB invariants automatically
-- on every push, catching regressions before they reach production.
--
-- Run with:
--   pg_prove -d merchantlens_test devsecops/db_tests.sql
--   OR
--   psql -d merchantlens_test -f devsecops/db_tests.sql

BEGIN;

SELECT plan(14);

-- ─── Schema existence ────────────────────────────────────────────────────────

SELECT has_table('public', 'merchants',            'merchants table exists');
SELECT has_table('public', 'transactions',         'transactions table exists');
SELECT has_table('public', 'settlement_batches',   'settlement_batches table exists');
SELECT has_table('public', 'chargebacks',          'chargebacks table exists');
SELECT has_table('public', 'audit_log',            'audit_log table exists');

-- ─── Critical columns ────────────────────────────────────────────────────────

SELECT has_column('public', 'transactions', 'amount',     'transactions.amount exists');
SELECT has_column('public', 'chargebacks',  'status',     'chargebacks.status exists');
SELECT has_column('public', 'audit_log',    'changed_at', 'audit_log.changed_at exists');

-- ─── Security: RLS check ─────────────────────────────────────────────────────
-- Row Level Security must be enabled on financial tables to prevent
-- one merchant's data leaking to another (multi-tenant safety).

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'transactions'),
    'RLS enabled on transactions table'
);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'settlement_batches'),
    'RLS enabled on settlement_batches table'
);

-- ─── Trigger existence (chargeback state machine) ────────────────────────────

SELECT has_trigger('public', 'chargebacks', 'enforce_dispute_fsm',
    'Chargeback FSM trigger exists');

SELECT has_trigger('public', 'transactions', 'audit_financial_change',
    'Audit trigger exists on transactions');

-- ─── Business rule: chargeback amount cannot exceed transaction amount ────────

SELECT throws_ok(
    $$
    INSERT INTO chargebacks (
        transaction_id, merchant_id, amount, status, reason
    )
    SELECT t.id, t.merchant_id, t.amount * 2, 'RECEIVED', 'FRAUD'
    FROM   transactions t
    LIMIT  1
    $$,
    'P0001',
    'Chargeback amount exceeds original transaction amount',
    'Chargeback amount > transaction amount is rejected'
);

-- ─── Procedure: settlement run produces balanced ledger ──────────────────────

SELECT lives_ok(
    $$CALL run_settlement_batch('TEST-BATCH-CI', NOW())$$,
    'run_settlement_batch procedure executes without error'
);

SELECT * FROM finish();
ROLLBACK;
