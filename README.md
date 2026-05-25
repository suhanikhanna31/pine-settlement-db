# MerchantLens — Merchant Settlement & Analytics Database

> A production-grade PostgreSQL system for payment settlement reconciliation, merchant analytics, and chargeback lifecycle management — purpose-built for the fintech/payments domain.
>
> **Now includes:** Java REST API layer · Salesforce CRM integration · Full DevSecOps CI/CD pipeline

---

## Real-World Impact

Pine Labs processes **billions of rupees** in daily merchant settlements. Chargebacks and reconciliation failures directly cost merchants money and erode trust. This project addresses three concrete pain points:

| Problem | What MerchantLens Does |
|---|---|
| Dispute analysts toggling between 3 tools | Salesforce Cases auto-created from DB events — single pane of glass |
| Rogue SQL queries hitting production DB | Java REST API layer enforces auth, rate limits, and schema contracts |
| Manual deployments breaking Salesforce metadata | DevSecOps pipeline with SAST, DAST, Apex PMD scan, and rollback |
| No audit trail for financial mutations | Tamper-resistant trigger-based audit log on every financial table |
| Chargeback ratios only caught monthly | Real-time rolling 7-day CB ratio alert query, surfaced in Salesforce dashboard |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     GitHub Actions CI/CD                         │
│  Secret Scan → SAST → DB Validate → Java Test → SF Validate     │
│              → DAST (main) → Deploy                              │
└──────────────────────┬──────────────────────────────────────────┘
                       │
         ┌─────────────▼──────────────┐
         │   Java Spring Boot API      │  ← JWT auth, OWASP hardened
         │   (DisputeController, etc.) │
         └──────┬──────────┬──────────┘
                │          │
   ┌────────────▼──┐  ┌────▼────────────────┐
   │  PostgreSQL   │  │  Salesforce CRM       │
   │  MerchantLens │  │  (Apex callout sync)  │
   │  DB           │  │  Cases, Dashboards    │
   └───────────────┘  └─────────────────────┘
```

---

## Project Structure

```
pine-settlement-db/
├── .github/workflows/
│   └── devsecops-pipeline.yml    # 7-stage DevSecOps pipeline
│
├── schema/                       # PostgreSQL schema (12 tables, 3NF)
├── indexes/                      # Composite, partial, expression indexes
├── triggers/                     # Audit log + chargeback FSM triggers
├── procedures/                   # Settlement run, dispute escalation, fee calc
├── queries/                      # Reconciliation, analytics, cohorts
├── seed/                         # 1000+ row realistic seed data
│
├── java-api/                     # Spring Boot REST API
│   └── src/main/java/com/merchantlens/
│       ├── controller/
│       │   └── DisputeController.java    # REST endpoints for disputes
│       ├── service/
│       │   └── DisputeService.java       # Business logic, DB calls
│       ├── model/
│       │   └── DisputeResponse.java      # Response DTO (no entity leakage)
│       └── security/
│           └── SecurityConfig.java       # JWT, CORS, HSTS, OWASP hardening
│
├── salesforce/                   # Salesforce DX project
│   └── force-app/main/default/
│       └── classes/
│           ├── MerchantDisputeSync.cls       # Apex callout → Salesforce Cases
│           └── MerchantDisputeSyncTest.cls   # 91% coverage, mock callouts
│
├── devsecops/
│   └── db_tests.sql              # pgTAP unit tests for CI DB validation stage
│
└── docs/
    └── schema_diagram.md         # Entity relationship description
```

---

## DevSecOps Pipeline (7 Stages)

```
Push / PR
    │
    ▼
[1] Secret Scan          — Gitleaks + TruffleHog (hardcoded credentials)
    │
    ▼
[2] SAST                 — SpotBugs (Java) + OWASP Dep-Check + SQLFluff (SQL injection patterns)
    │
    ▼
[3] DB Validation        — Schema applied to ephemeral Postgres, pgTAP tests run
    │
    ▼
[4] Java Tests           — Maven unit + integration tests, JaCoCo ≥70% gate
    │
    ▼
[5] Salesforce Validate  — SF CLI check-only deploy + PMD Apex static analysis
    │
    ▼
[6] DAST (main only)     — OWASP ZAP baseline scan against staging
    │
    ▼
[7] Deploy               — DB migrations + Docker API push + SF metadata deploy + Slack notify
```

**Why this matters for AutoRABIT:** AutoRABIT ARM does exactly this for enterprise Salesforce orgs — version-controlled metadata, automated testing gates, and safe rollback. This pipeline demonstrates the same principles built from first principles.

---

## Salesforce Integration

### What it does
The `MerchantDisputeSync` Apex class syncs chargeback data from MerchantLens into Salesforce Cases on an hourly schedule. When a dispute escalates to `ARBITRATION` status in the DB (enforced by the FSM trigger), the linked Salesforce Case automatically updates to `Escalated` priority — merchant support teams get real-time alerts without leaving Salesforce.

### Security design
- Named Credentials used — no API keys in Apex code
- `with sharing` enforced — Salesforce sharing rules respected
- `@future(callout=true)` for async execution — no governor limit violations
- External ID upsert — idempotent, safe to re-run on failure

### Running the Apex
```bash
# Authenticate to sandbox
sf org login web --alias merchantlens-sandbox

# Deploy classes
sf project deploy start \
  --source-dir salesforce/force-app \
  --target-org merchantlens-sandbox \
  --test-level RunLocalTests

# Trigger manual sync for a merchant
sf apex run --file scripts/trigger_sync.apex --target-org merchantlens-sandbox
```

---

## Java API Quick Start

```bash
cd java-api

# Run with test profile (H2 in-memory DB)
mvn spring-boot:run -Dspring.profiles.active=test

# Run against local Postgres
export DB_URL=jdbc:postgresql://localhost:5432/merchantlens
export DB_USER=ml_user
export DB_PASS=yourpassword
mvn spring-boot:run

# Test endpoints
curl -H "Authorization: Bearer <jwt>" \
     http://localhost:8080/api/v1/disputes?updated_since=24h

curl -H "Authorization: Bearer <jwt>" \
     http://localhost:8080/api/v1/disputes/summary
```

---

## PostgreSQL Quick Start

```bash
createdb merchantlens

psql -d merchantlens -f schema/01_enums.sql
psql -d merchantlens -f schema/02_core_tables.sql
psql -d merchantlens -f schema/03_transaction.sql
psql -d merchantlens -f schema/04_settlement.sql
psql -d merchantlens -f schema/05_disputes.sql
psql -d merchantlens -f indexes/01_indexes.sql
psql -d merchantlens -f triggers/01_audit_trigger.sql
psql -d merchantlens -f triggers/02_dispute_fsm.sql
psql -d merchantlens -f procedures/01_run_settlement.sql
psql -d merchantlens -f procedures/02_escalate_disputes.sql
psql -d merchantlens -f procedures/03_compute_fees.sql
psql -d merchantlens -f seed/01_seed_data.sql

# Run analytics
psql -d merchantlens -f queries/02_merchant_analytics.sql
```

---

## Key Design Decisions

### 1. API layer over direct DB access
Exposing the DB directly to Salesforce callouts would mean sharing superuser credentials and no request validation. The Spring Boot API enforces JWT auth, rate limiting, and field-level DTO filtering — consistent with how AutoRABIT's platform isolates Salesforce org access from underlying infrastructure.

### 2. Chargeback state machine in a trigger (not application code)
Valid transitions (`RECEIVED → UNDER_REVIEW → WON | LOST | ARBITRATION`) are enforced in a `BEFORE UPDATE` trigger. No service — Java, Apex, or a rogue `psql` session — can corrupt the lifecycle. This mirrors how AutoRABIT enforces deployment state transitions in its pipeline engine.

### 3. Audit log is tamper-resistant
Written by a DB trigger, not application code. Even if the Java API or Apex class is compromised, every financial mutation is logged. PCI-DSS and RBI audit requirements for payment platforms demand exactly this.

### 4. Salesforce upsert uses External ID
`MerchantLens_Dispute_ID__c` as the upsert key means the hourly sync is fully idempotent. Re-running on failure never creates duplicate Cases — a critical requirement when integrating two transactional systems.

### 5. DevSecOps: security gates before every deploy
The pipeline blocks deployment if any of these fail: secret scan, SpotBugs, OWASP dependency vulnerabilities ≥CVSS 7, coverage < 70%, SF PMD severity ≥ 3, or DAST findings. This is the "Sec" in DevSecOps — security is a quality gate, not an afterthought.

---

## Sample Query Output

```
-- Rolling 7-day chargeback ratio by merchant
merchant_name         | txn_count | dispute_count | cb_ratio_pct | alert
----------------------+-----------+---------------+--------------+-------
Zudio Retail          |      4821 |            31 |         0.64 | false
Haldiram's Express    |      2103 |            29 |         1.38 | true   ← threshold breach
Chai Point            |      1897 |             8 |         0.42 | false
```

When `alert = true`, the Salesforce integration creates a high-priority Case for the merchant success team automatically.

---

## Skills Demonstrated

| Layer | Skill |
|---|---|
| **Database** | 12-table normalized schema, window functions, CTEs, PL/pgSQL procedures, FSM triggers, partial indexes |
| **Java** | Spring Boot REST API, Spring Security (JWT, CORS, HSTS), DTO pattern, JaCoCo coverage |
| **Salesforce** | Apex HTTP callouts, Named Credentials, `with sharing`, InvocableMethod, test mocks |
| **DevSecOps** | 7-stage GitHub Actions pipeline, SAST (SpotBugs, OWASP), DAST (ZAP), pgTAP DB tests, secret scanning |
| **Domain** | Fintech/payments reconciliation, chargeback lifecycle, MDR fee computation, settlement lag analytics |
