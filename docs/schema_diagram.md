# Schema Diagram — MerchantLens

## Entity Relationship Overview

```
merchants (1) ──────────────────────────── (N) merchant_bank_accounts
    │
    ├── (N) terminals
    │       │
    │       └── (N) authorizations
    │                   │
    │                   └── (N) captures ──── (N) refunds
    │                               │
    │                               ├── (N) settlement_line_items
    │                               │           │
    │                               │    settlement_batches (1)
    │                               │           │
    │                               │        payouts (1)
    │                               │
    │                               └── (N) disputes
    │                                       │
    │                                       └── (N) dispute_evidence
    │
    └── (N) fee_config
```

## Table Descriptions

| Table | Rows (approx) | Purpose |
|---|---|---|
| `merchants` | ~10K | Business entities onboarded to accept payments |
| `merchant_bank_accounts` | ~12K | Bank accounts for settlement payouts |
| `terminals` | ~100K | Physical/virtual acceptance devices |
| `fee_config` | ~50K | MDR/interchange rate configurations |
| `authorizations` | ~500M | Payment reservations from card networks |
| `captures` | ~490M | Actual fund movements |
| `refunds` | ~20M | Reversal of captures |
| `settlement_batches` | ~5M | Daily/T+N groupings of captures |
| `settlement_line_items` | ~500M | One row per capture or refund in a batch |
| `payouts` | ~5M | NEFT/IMPS credits to merchant banks |
| `reconciliation_mismatches` | ~100K | Discrepancies vs. network files |
| `disputes` | ~10M | Chargebacks filed by cardholders |
| `dispute_evidence` | ~30M | Supporting documents for dispute defense |
| `audit_log` | ~2B | Immutable change history |

## Key Relationships

- `authorizations.terminal_id` → `terminals.terminal_id`
- `captures.auth_id` → `authorizations.auth_id`
- `captures.settlement_batch_id` → `settlement_batches.batch_id`
- `refunds.capture_id` → `captures.capture_id`
- `settlement_line_items.batch_id` → `settlement_batches.batch_id`
- `payouts.batch_id` → `settlement_batches.batch_id` (UNIQUE: one payout per batch)
- `disputes.capture_id` → `captures.capture_id`

## Design Principles

1. **All monetary values in paise** (integer arithmetic, no floating point errors)
2. **UUIDs for all PKs** (safe for distributed ID generation)
3. **Timestamps as TIMESTAMPTZ** (stored as UTC, displayed in IST via session timezone)
4. **Soft deletes via `is_active`** for merchants and terminals
5. **Generated columns** for computed amounts (`net_amount_paise`, `delta_paise`)
6. **Domain enums** for all status fields (database-enforced, self-documenting)
