# PaySecure DR Runbook: RB-02 Database Corruption

## 1. Scenario Identification
- **Runbook ID**: RB-02
- **Scenario Name**: Logical Data Corruption in Primary Aurora PostgreSQL Database
- **Category**: Data Integrity / Software Defect
- **Severity Classification**: P1 - Critical Data Integrity Incident
- **Target RTO**: < 15 Minutes
- **Target RPO**: Point-in-Time Recovery to Last Known Clean Transaction (T - 15m)
- **Affected Components**: Amazon Aurora PostgreSQL (`paysecure-primary`), read replicas, downstream settlement batch files, and merchant ledger balances (~4,800 transactions affected).
- **Incident Commander Role**: Lead Database Administrator / Principal Architect
- **Secondary Roles**: Primary SRE, Head of Settlement & Reconciliation, Compliance Officer

---

## 2. Detection Mechanism
1. **Integrity Constraint Alert**: `AuroraTransactionCheckFailureRateHigh`
   - Metric: Custom CloudWatch Metric `PaySecure/Database -> ChecksumMismatches` > 5 errors/min.
2. **Reconciliation Discrepancy Alert**: `NodalAccountBalanceImbalanceDetected`
   - Prometheus Rule: `increase(settlement_ledger_discrepancy_count[5m]) > 0`.
3. **Application Log Pattern**: Alert on Elasticsearch query `status: "CORRUPTED_LEDGER_ENTRY"` or `ERROR: invalid page in block`.

---

## 3. Impact Assessment
- **Corrupted Records**: Approximately 4,800 transaction ledger rows with corrupted status flags or incorrect ledger debits over a 15-minute software defect window.
- **Financial Exposure**: Risk of processing duplicate merchant payouts worth ₹2.4 Crore INR if uncorrected prior to the 16:00 IST nodal clearing cutoff.
- **Regulatory Exposure**: Under Section 43A of the IT Act and RBI Master Direction, data corruption affecting financial records mandates immediate regulatory logging and forensic preservation.

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge Data Integrity Alert | Lead DBA | PagerDuty ACK on Incident `#PSG-DB-CORRUPT` | Alert acknowledged; team paged |
| **2** | Isolate Application Write Ingress | Primary SRE | `kubectl -n paysecure scale deployment payment-api --replicas=0` | Halts write requests immediately to prevent propagating corrupted writes |
| **3** | Place Ingress ALB in Maintenance Mode | Primary SRE | `aws elbv2 modify-listener --listener-arn $ALB_LISTENER_ARN --default-actions Type=fixed-response,FixedResponseConfig="{StatusCode=503,ContentType=text/plain,MessageBody='Gateway under scheduled integrity maintenance'}"` | External clients receive safe 503 retry responses |
| **4** | Freeze Aurora Global Database Replication | Lead DBA | `aws rds stop-db-instance --db-instance-identifier paysecure-secondary-instance-1 --region ap-south-2` | Prevents corrupt storage blocks from replicating further into Hyderabad |
| **5** | Create Emergency Snapshot of Corrupted Database | Lead DBA | `aws rds create-db-cluster-snapshot --db-cluster-identifier paysecure-primary --db-cluster-snapshot-identifier paysecure-corrupt-forensic-$(date +%s)` | Forensic evidence preserved for RCA and audit |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **6** | Determine Exact Corruption Start Timestamp | Lead DBA | `SELECT MIN(created_at) FROM transactions WHERE status = 'CORRUPTED' OR metadata->>'error' = 'INVALID_CHECKSUM';` | Identifies exact start time ($T_{	ext{corrupt}} = 	ext{2026-09-12 11:45:00 UTC}$) |
| **7** | Query Total Impacted Records | Lead DBA | `SELECT count(*), sum(amount) FROM transactions WHERE created_at >= '2026-09-12 11:45:00 UTC';` | Returns count (~4,821 rows, ₹74.2 Lakh INR) |
| **8** | Identify Corrupted Database Tables | Lead DBA | `SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables WHERE relname IN ('transactions', 'settlement_entries');` | Confirms corruption is localized to `transactions` table |
| **9** | Review Application Git Deployment History | Primary SRE | `kubectl describe deployment transaction-processor | grep Image` | Identifies buggy release `v2.4.1` deployed at 11:44 UTC |

---

## 6. Failover & Recovery Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **10** | **DECISION BRANCH 1**: PITR vs. In-Place SQL Patch | Lead DBA | *If corruption > 1,000 rows -> Execute Point-In-Time Recovery (PITR). If < 50 rows -> Execute compensatory SQL patch.* | Branch A: PITR mandated due to 4,800 corrupted rows |
| **11** | Initiate Aurora Point-In-Time Recovery | Lead DBA | `aws rds restore-db-cluster-to-point-in-time --source-db-cluster-identifier paysecure-primary --db-cluster-identifier paysecure-recovery-clean --restore-to-time 2026-09-12T11:44:50Z --restore-type full-copy --db-subnet-group-name paysecure-data-subnets` | Restores pristine cluster from storage blocks at $T-15	ext{s}$ prior to buggy deploy |
| **12** | Roll Back Application Deployment | Primary SRE | `kubectl -n paysecure rollout undo deployment transaction-processor` | Reverts pods to stable image `v2.4.0` |
| **13** | Monitor PITR Cluster Availability | Lead DBA | `aws rds describe-db-clusters --db-cluster-identifier paysecure-recovery-clean --query 'DBClusters[0].Status'` | Status reaches `available` (~8 minutes) |
| **14** | Create Instance on Clean Recovery Cluster | Lead DBA | `aws rds create-db-instance --db-cluster-identifier paysecure-recovery-clean --db-instance-identifier paysecure-recovery-inst-1 --db-instance-class db.r6g.2xlarge --engine aurora-postgresql` | Compute instance online and accepting queries |
| **15** | Extract Lost Legitimate Transactions from Corrupted Snapshot | Lead DBA | Run `scripts/failover/extract-clean-records.py --source paysecure-corrupt-forensic --target paysecure-recovery-clean --since 2026-09-12T11:45:00Z` | Extracts and replays 4,680 valid payments using bank reference numbers |
| **16** | Validate Restored Database Row Integrity | Lead DBA | `SELECT count(*) FROM transactions WHERE check_checksum(id, amount, status) = true;` | 100% rows verified with clean cryptographic checksums |
| **17** | Switch Internal Service DNS to Clean Cluster | Primary SRE | `kubectl -n paysecure patch configmap region-config -p '{"data":{"aurora-endpoint":"paysecure-recovery-clean.cluster-xyz.ap-south-1.rds.amazonaws.com"}}'` | EKS pods re-pointed to clean restored cluster |
| **18** | Re-scale Compute Services | Primary SRE | `kubectl -n paysecure scale deployment payment-api --replicas=18` | Payment processing pods resumed |
| **19** | Reopen Public Ingress on ALB | Primary SRE | `aws elbv2 modify-listener --listener-arn $ALB_LISTENER_ARN --default-actions file://configs/alb-production-rules.json` | 503 maintenance mode removed; production traffic restored |

---

## 7. Communication Protocol
- **Engineering Comms**: `[P1 DATA INCIDENT] Aurora Corruption Isolated. PITR Completed to 11:44:50Z. Buggy deployment v2.4.1 rolled back.`
- **Merchant Comms**: Advisory posted: `PaySecure gateway experienced a 12-minute maintenance window for ledger verification. All transactions are fully reconciled.`
- **Regulatory Comms**: Notification sent to RBI DPSS confirming logical fault contained with zero unverified bank settlements.

---

## 8. Verification & Validation
- Run reconciliation query: `SELECT count(*) FROM settlement_entries WHERE debit != credit;` -> Must return `0`.
- Verify synthetic transaction: `curl https://api.paysecure.in/health/deep` -> Returns `200 OK`.

---

## 9. Rollback Procedure
If restored clean database fails performance benchmark:
1. Promote Hyderabad replica cluster immediately as clean master.
2. Invert Route 53 to Hyderabad while continuing forensic analysis in Mumbai.

---

## 10. Post-Incident Review Checklist
- [ ] Implement pre-deployment automated database migration contract tests in CI/CD pipeline.
- [ ] Add static analysis rule forbidding unchecked raw pointer mutations in `transaction-processor`.
- [ ] File formal report with Internal Audit and RBI within 48 hours.
