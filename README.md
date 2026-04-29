# MerchantLens — Merchant Settlement & Analytics Database

> A production-grade PostgreSQL system for payment settlement reconciliation, merchant analytics, and chargeback lifecycle management — purpose-built for the fintech/payments domain.

---

## What This Project Demonstrates

| Skill | Detail |
|---|---|
| Schema Design | 12-table normalized schema (3NF) with FK constraints, check constraints, partial indexes |
| Query Optimization | Window functions, CTEs, lateral joins, explain-plan-aware query design |
| Stored Procedures | PL/pgSQL procedures for settlement runs, dispute escalation, fee computation |
| Triggers | Audit log trigger, chargeback-state-machine enforcement trigger |
| Indexing Strategy | Composite, partial, and expression indexes; covering indexes for hot queries |
| Reconciliation Logic | Multi-leg transaction matching with tolerance-based mismatch detection |
| Analytics | Merchant GMV cohorts, rolling 7-day settlement lag, chargeback ratio alerting |

---

## Domain Context

Pine Labs processes billions of rupees in daily merchant settlements. Between a card swipe and the merchant seeing money in their account, many steps occur:

```
Card Swipe → Authorization → Capture → Batch Close → Network Settlement → Bank Credit → Merchant Payout
```

This project models the **middle layers**: how a payments platform stores, reconciles, and reports on those steps.

---

## Project Structure

```
pine-settlement-db/
├── schema/
│   ├── 01_enums.sql          # Domain enums (payment_method, dispute_status, …)
│   ├── 02_core_tables.sql    # Merchants, terminals, bank accounts
│   ├── 03_transaction.sql    # Transactions, captures, refunds
│   ├── 04_settlement.sql     # Settlement batches, line items, payouts
│   └── 05_disputes.sql       # Chargebacks, evidence, decisions
├── indexes/
│   └── 01_indexes.sql        # All indexes with rationale comments
├── triggers/
│   ├── 01_audit_trigger.sql  # Row-level audit log for financial tables
│   └── 02_dispute_fsm.sql    # Chargeback state-machine enforcement
├── procedures/
│   ├── 01_run_settlement.sql     # Settlement batch procedure
│   ├── 02_escalate_disputes.sql  # Auto-escalate stale disputes
│   └── 03_compute_fees.sql       # MDR + interchange fee calculator
├── queries/
│   ├── 01_reconciliation.sql     # Identify unmatched / mismatched transactions
│   ├── 02_merchant_analytics.sql # GMV, chargeback ratio, settlement lag
│   ├── 03_top_merchants.sql      # Window-function ranking queries
│   └── 04_cohort_analysis.sql    # Monthly GMV cohort with retention
├── seed/
│   └── 01_seed_data.sql          # Realistic sample data (1 000+ rows)
└── docs/
    └── schema_diagram.md         # Entity relationship description
```

---

## Quick Start

```bash
# 1. Create the database
createdb merchantlens

# 2. Run all schema files in order
psql -d merchantlens -f schema/01_enums.sql
psql -d merchantlens -f schema/02_core_tables.sql
psql -d merchantlens -f schema/03_transaction.sql
psql -d merchantlens -f schema/04_settlement.sql
psql -d merchantlens -f schema/05_disputes.sql

# 3. Create indexes
psql -d merchantlens -f indexes/01_indexes.sql

# 4. Install triggers
psql -d merchantlens -f triggers/01_audit_trigger.sql
psql -d merchantlens -f triggers/02_dispute_fsm.sql

# 5. Install procedures
psql -d merchantlens -f procedures/01_run_settlement.sql
psql -d merchantlens -f procedures/02_escalate_disputes.sql
psql -d merchantlens -f procedures/03_compute_fees.sql

# 6. Load seed data
psql -d merchantlens -f seed/01_seed_data.sql

# 7. Run sample analytics queries
psql -d merchantlens -f queries/02_merchant_analytics.sql
```

---

## Key Design Decisions

### 1. Separate `capture` from `authorization`
Authorizations can be reversed or partially captured. Storing them as separate rows with a FK relationship (rather than a status column) makes partial-capture accounting correct by construction.

### 2. Settlement as a two-phase ledger
A `settlement_batch` aggregates many `settlement_line_items`. A `payout` references a batch. This mirrors how real networks (Visa, Mastercard) send net-settlement files before banks credit accounts.

### 3. Chargeback state machine in a trigger
Valid state transitions (`RECEIVED → UNDER_REVIEW → WON | LOST | ARBITRATION`) are enforced in a `BEFORE UPDATE` trigger, not in application code, so no rogue UPDATE can corrupt the lifecycle regardless of which service issues it.

### 4. Partial indexes on `pending` rows
Operational queries almost always filter on `status = 'PENDING'`. Partial indexes on this predicate are 10–50× smaller than full indexes, fitting entirely in `shared_buffers` for sub-millisecond lookups.

### 5. Audit log via trigger (not application layer)
Every `INSERT / UPDATE / DELETE` on financial tables is written to `audit_log` by a trigger. This is tamper-resistant — even a compromised application cannot skip the audit trail.

---

## Sample Query Output

```
-- Rolling 7-day chargeback ratio by merchant
merchant_name         | txn_count | dispute_count | cb_ratio_pct
----------------------+-----------+---------------+-------------
Zudio Retail          |      4821 |            31 |         0.64
Haldiram's Express    |      2103 |            29 |         1.38  ← alert threshold
Chai Point            |      1897 |             8 |         0.42
```
