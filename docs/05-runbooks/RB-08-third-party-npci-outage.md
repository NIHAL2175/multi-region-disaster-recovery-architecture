# PaySecure DR Runbook: RB-08 Third-Party Payment Network Outage (NPCI/UPI)

## 1. Scenario Identification
- **Runbook ID**: RB-08
- **Scenario Name**: Nationwide NPCI UPI Network Outage / Major Partner Bank Host Failure
- **Category**: External Network / Third-Party Rail Failure
- **Severity Classification**: P2 - High External Service Outage (Gateway Operational)
- **Target RTO**: Rail De-prioritization < 60 Seconds; Merchant Communication < 2 Minutes
- **Target RPO**: Zero Transaction Loss (RPO = 0)
- **Affected Components**: UPI payment method integration, bank adapter microservices, customer checkout payment options.
- **Incident Commander Role**: Principal FinTech Solutions Architect
- **Secondary Roles**: NPCI Rail Operations Liaison, Merchant Success Lead, Lead Frontend SRE

---

## 2. Detection Mechanism
1. **UPI Network Error Rate Spike**: `UPISuccessRateDropSevere`
   - Metric: `paysecure_upi_transactions_success_ratio < 0.30` (70% failures on UPI rail over 2 minutes).
2. **NPCI Connection Timeout Alert**: `NPCIAdapterTimeoutHigh`
   - Prometheus Alert: `rate(bank_adapter_http_timeouts_total{bank="NPCI_UPI"}[1m]) > 50`.
3. **External NPCI Incident Broadcast**: Official circular received via NPCI Member Portal / WhatsApp Emergency Bridge.

---

## 3. Impact Assessment
- **Payment Method Disruption**: UPI represents 68% of PaySecure's 3.2M daily transactions (~2.17M transactions/day).
- **Merchant Impact**: Consumers facing UPI authorization timeouts on e-commerce checkouts.
- **PaySecure Infrastructure State**: **100% HEALTHY**. Internal databases, EKS pods, and card networks operate normally.

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge External Outage Alert | Rail Ops Lead | PagerDuty ACK on Incident `#PSG-EXT-UPI` | FinTech War Room initiated |
| **2** | Confirm External vs Internal Root Cause | Rail Ops Lead | `curl -Iv https://upi-switch.npci.org.in:8443/heartbeat` | Times out; external NPCI network confirmed down |
| **3** | Enable Dynamic Checkout Payment Method De-prioritization | Lead SRE | `aws dynamodb update-item --table-name paysecure-config --key '{"key":{"S":"CHECKOUT_PAYMENT_METHODS"}}' --update-expression 'SET upi_active = :val' --expression-attribute-values '{":val":{"BOOL":false}}'` | Dynamic checkout moves Cards, NetBanking, and Wallets to top priority |
| **4** | Activate Smart Auto-Retry Queue for In-Flight UPI Calls | Primary SRE | `kubectl -n paysecure patch configmap region-config -p '{"data":{"UPI_QUEUE_SUSPEND_RETRY":"true"}}'` | Holds pending UPI callbacks in Redis buffer rather than returning immediate failures |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Inspect Alternate Card & NetBanking Success Rates | Rail Ops Lead | `sum(rate(transaction_success_total{method=~"cards|netbanking"}[5m]))` | Confirms Visa, Mastercard, and NetBanking success rates remain > 99.2% |
| **6** | Query Pending UPI Callback Backlog | Data Eng | `SELECT count(*) FROM transactions WHERE method = 'UPI' AND status = 'PENDING_BANK_CONFIRMATION';` | Identifies exact in-flight transaction count (~3,200 txns) |
| **7** | Check NPCI Member Communications | Rail Ops Lead | Monitor NPCI Emergency Bridge `#npci-incident-desk` | Tracks estimated restoration time from NPCI NOC |

---

## 6. Merchant Steering & Recovery Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **8** | Broadcast Merchant Advisory Banner | Merchant Lead | Trigger Merchant Portal Notification: *"NPCI experiencing nationwide UPI degradation. Card and NetBanking rails are 100% operational."* | 45,000 merchants alerted; customer inquiries reduced |
| **9** | Monitor NPCI Network Recovery | Rail Ops Lead | `python scripts/health-checks/probe-npci-recovery.py` | Automated script sends 1 probe every 15s to detect recovery |
| **10** | Re-enable UPI Rail with Canary Ramp | Rail Ops Lead | `aws dynamodb update-item --table-name paysecure-config --key '{"key":{"S":"CHECKOUT_PAYMENT_METHODS"}}' --update-expression 'SET upi_canary_pct = :val' --expression-attribute-values '{":val":{"N":"10"}}'` | Routes 10% UPI traffic first to verify switch stability |
| **11** | Verify Canary UPI Success Rate | Rail Ops Lead | `rate(transaction_success_total{method="UPI"}[2m]) > 0.98` | Confirms NPCI switch is processing smoothly |
| **12** | Scale UPI to 100% Production | Rail Ops Lead | Set `upi_active = true` and `upi_canary_pct = 100` | Full UPI checkout restored |
| **13** | Drain In-Flight Pending Callback Buffer | Lead DBA | Trigger `scripts/failover/drain-upi-callbacks.py` | Queries NPCI UTR status for all 3,200 pending transactions; credits merchant ledgers |

---

## 7. Communication Protocol
- **Merchant Advisory**: Advisory sent via portal and WhatsApp API: `UPI payment processing has been restored across all banks. All held transactions are reconciled.`
- **Internal Executive Update**: Board Chair and VP Engineering notified of external incident containment.

---

## 8. Verification & Validation
- Confirm UPI TPS: `rate(paysecure_upi_transactions_total[1m]) > 800 TPS`.
- Confirm 0 pending callbacks older than 10 minutes.

---

## 9. Rollback Procedure
If NPCI experiences second wave of flapping errors:
1. Immediately revert `upi_active = false` in DynamoDB config.
2. Maintain Cards and NetBanking routing.

---

## 10. Post-Incident Review Checklist
- [ ] Reconcile NPCI daily clearing file against PaySecure internal ledger.
- [ ] File capacity adequacy feedback with NPCI Technical Committee.
- [ ] Ensure merchant chargebacks for duplicate attempts during outage are automatically suppressed.
