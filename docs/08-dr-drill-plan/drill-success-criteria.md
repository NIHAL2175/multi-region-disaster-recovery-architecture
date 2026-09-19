# PaySecure Gateway: Disaster Recovery Drill Success Criteria & Scoring Rubrics

**Document ID**: PSG-BCP-002-CRIT  
**Evaluation Standard**: Binary Go/No-Go Production Readiness Gates  

---

## 1. Quantitative SLA Evaluation Gates

Every disaster recovery drill is evaluated against five mandatory quantitative gates. A drill is declared **SUCCESSFUL** only if 100% of the following criteria are satisfied:

```
+---------------------------------------------------------------------------------------------------+
| Quantitative Disaster Recovery Evaluation Gates                                                   |
+--------------------+-------------------------+----------------------+-----------------------------+
| Evaluation Metric  | Target Threshold        | Failing Threshold    | Measurement Tool / Query    |
+--------------------+-------------------------+----------------------+-----------------------------+
| 1. Real-World RTO  | < 4 Minutes 00 Seconds  | >= 5 Minutes 00 Sec  | CloudWatch Synthetics       |
|    (Recovery Time) | (Design: 3m 30s)        | (Violates RBI SLA)   | Ingress Restoration Time    |
+--------------------+-------------------------+----------------------+-----------------------------+
| 2. Real-World RPO  | < 1.0 Second            | >= 60.0 Seconds      | Maximum Replication Lag     |
|    (Data Loss)     | (Aurora Storage Lag)    | (Violates RBI Tier-1)| at Moment of Detachment     |
+--------------------+-------------------------+----------------------+-----------------------------+
| 3. Ingress 5xx     | < 0.10% of total calls  | >= 1.00% of total    | ALB HTTPCode_Target_5XX_    |
|    Error Rate      | during failover window  | transaction requests | Count / Total Requests      |
+--------------------+-------------------------+----------------------+-----------------------------+
| 4. Transaction P99 | < 250 ms in Hyderabad   | >= 300 ms            | Prometheus P99 Trace Span:  |
|    Latency         | (Comfortable buffer)    | (Violates NPCI SLA)  | http_request_duration_p99   |
+--------------------+-------------------------+----------------------+-----------------------------+
| 5. Financial Data  | EXACTLY 0 Discrepancies | >= 1 Unmatched Row   | python scripts/failover/    |
|    Reconciliation  | (100% Ledger Matched)   | (Split-brain failure)| reconcile-split-brain.py    |
+--------------------+-------------------------+----------------------+-----------------------------+
```

---

## 2. Arena Mode Scoring Rubric (100-Point System)

In alignment with the Assessment Board criteria, drills and runbook executions are scored across five distinct quality dimensions:

1. **Step Completeness (25 Points)**:
   - *25/25*: Every necessary action documented; zero procedural gaps; clean rollback steps included.
   - *< 12/25*: Missing critical steps; logical gaps in failover sequence; absent rollback protocol.
2. **Command Accuracy (25 Points)**:
   - *25/25*: All AWS CLI, kubectl, and SQL commands syntactically valid with accurate regional parameters and ARNs.
   - *< 12/25*: Commands fail on execution; incorrect AWS CLI v2 flags; referencing non-existent endpoints.
3. **Timing Feasibility (20 Points)**:
   - *20/20*: Timing estimates backed by documented AWS service SLA benchmarks; total recovery within 3.5 minutes.
   - *< 10/20*: Unrealistic timing; failover exceeds RTO target by 2x+.
4. **Decision Tree Quality (15 Points)**:
   - *15/15*: 5+ quantified decision branch points covering edge cases, network splits, and cascading loops.
   - *< 7/15*: Linear "happy path" procedure with no conditional branching.
5. **Communication Protocol (15 Points)**:
   - *15/15*: Comprehensive notification templates for internal engineering, C-suite, 45,000 merchants, and statutory regulators (RBI, NPCI, CERT-In).
   - *< 7/15*: Generic "notify team" bullet points without formal templates.
