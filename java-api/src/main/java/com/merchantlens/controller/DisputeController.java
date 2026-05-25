package com.merchantlens.controller;

import com.merchantlens.model.DisputeResponse;
import com.merchantlens.service.DisputeService;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * DisputeController.java
 *
 * REST API endpoint for dispute/chargeback data.
 * Consumed by the Salesforce Apex callout (MerchantDisputeSync)
 * and internal dashboards.
 *
 * Security:
 *  - JWT authentication via Spring Security (configured in SecurityConfig)
 *  - Role-based access: ANALYST and ADMIN can read; only ADMIN can trigger bulk ops
 *  - All endpoints are HTTPS-only (enforced at load-balancer level)
 *  - Input validated via Bean Validation (@Valid) — no raw SQL constructed here
 *
 * Real-World Impact:
 *  This layer acts as the bridge between the PostgreSQL settlement DB
 *  and downstream consumers (Salesforce CRM, internal React dashboard,
 *  mobile apps). Without it, teams would query prod DB directly —
 *  a common cause of accidental data mutations and performance incidents.
 */
@RestController
@RequestMapping("/api/v1/disputes")
public class DisputeController {

    private final DisputeService disputeService;

    public DisputeController(DisputeService disputeService) {
        this.disputeService = disputeService;
    }

    /**
     * GET /api/v1/disputes
     *
     * Supports filters:
     *   ?updated_since=24h   — disputes updated in last N hours
     *   ?merchant_id=M-42    — filter by merchant
     *   ?status=UNDER_REVIEW — filter by lifecycle status
     *
     * Used by: Salesforce sync job, internal dashboard
     */
    @GetMapping
    @PreAuthorize("hasAnyRole('ANALYST', 'ADMIN')")
    public ResponseEntity<List<DisputeResponse>> getDisputes(
            @RequestParam(required = false) String updated_since,
            @RequestParam(required = false) String merchant_id,
            @RequestParam(required = false) String status) {

        List<DisputeResponse> disputes =
            disputeService.findDisputes(updated_since, merchant_id, status);

        return ResponseEntity.ok(disputes);
    }

    /**
     * GET /api/v1/disputes/{id}
     * Returns a single dispute with full evidence chain and timeline.
     */
    @GetMapping("/{id}")
    @PreAuthorize("hasAnyRole('ANALYST', 'ADMIN')")
    public ResponseEntity<DisputeResponse> getDisputeById(@PathVariable String id) {
        return disputeService.findById(id)
            .map(ResponseEntity::ok)
            .orElse(ResponseEntity.notFound().build());
    }

    /**
     * POST /api/v1/disputes/{id}/escalate
     *
     * Manually escalates a dispute to ARBITRATION status.
     * Calls the stored procedure `escalate_disputes()` for a single dispute.
     * Triggers Salesforce webhook to update the linked Case priority.
     *
     * ADMIN-only: analysts can view but not escalate.
     */
    @PostMapping("/{id}/escalate")
    @PreAuthorize("hasRole('ADMIN')")
    public ResponseEntity<DisputeResponse> escalateDispute(@PathVariable String id) {
        DisputeResponse updated = disputeService.escalate(id);
        return ResponseEntity.ok(updated);
    }

    /**
     * GET /api/v1/disputes/summary
     *
     * Returns chargeback ratio summary per merchant (last 30 days).
     * Powers the Salesforce Lightning dashboard component.
     *
     * Example response:
     * [
     *   {"merchantName": "Chai Point", "cbRatioPct": 0.42, "alert": false},
     *   {"merchantName": "Haldiram's", "cbRatioPct": 1.38, "alert": true}
     * ]
     */
    @GetMapping("/summary")
    @PreAuthorize("hasAnyRole('ANALYST', 'ADMIN')")
    public ResponseEntity<?> getDisputeSummary() {
        return ResponseEntity.ok(disputeService.getChargebackRatioSummary());
    }
}
