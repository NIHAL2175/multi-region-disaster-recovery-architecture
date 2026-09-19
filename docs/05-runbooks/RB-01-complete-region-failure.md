# PaySecure DR Runbook: RB-01 Complete Primary Region Failure

## 1. Scenario Identification
- **Runbook ID**: RB-01
- **Scenario Name**: Complete Catastrophic Failure of Primary Region (`ap-south-1` Mumbai)
- **Category**: Infrastructure / Regional Catastrophe
- **Severity Classification**: P1 - Fatal / Critical Business Emergency
- **Target RTO**: < 5 Minutes (Design Verification: 3 Minutes 30 Seconds)
- **Target RPO**: < 1 Minute (Design Verification: < 1.0 Second)
- **Affected Components**: All infrastructure in `ap-south-1`: 24 EKS nodes (~180 pods), Aurora PostgreSQL Writer & Readers, ElastiCache Redis Primary Cluster, Amazon MSK Kafka Cluster, Transit Gateway Hub, Dual Ingress ALBs, and NAT Gateways.
- **Incident Commander Role**: Principal SRE On-Call / Head of Infrastructure
- **Secondary Roles**: Lead DBA on rotation, Cloud Security Lead, Merchant Comms Lead

---

## 2. Detection Mechanism
1. **Primary Alert**: `Route53CalculatedHealthCheckFailed`
   - Metric: `AWS/Route53 -> HealthCheckStatus`
   - Evaluation: Value = 0 (Unhealthy) for 3 consecutive 10-second checks across >= 3 health checker regions.
2. **Synthetic API Probe Alert**: `PaymentApiGlobalSyntheticFailure`
   - Prometheus Alert: `probe_success{job="blackbox_payment_api_mum"} == 0` for 30 seconds.
3. **Database Unreachable Composite**: `AuroraPrimaryUnreachable`
   - CloudWatch Alarm: `AWS/RDS -> DatabaseConnections` drops to 0 across all Mumbai instances.
4. **Automated Escalation**: PagerDuty triggers `PAYSECURE_SEV1_WAR_ROOM` paging Incident Commander, Lead DBA, VP Engineering, and Chief Risk Officer within 20 seconds.

---

## 3. Impact Assessment
- **Transactional Volume Impact**: 100% loss of incoming payment processing (~1,200 peak TPS blocked, ~250 TPS business-hour baseline).
- **Financial Revenue at Risk**: ₹37.5 Lakh INR revenue per hour lost at 1.8% MDR (~₹62,500 INR/minute); ₹20.83 Crore INR/hour in blocked transaction value.
- **Merchant Impact**: 45,000 active merchants unable to process payments; customer checkout abandonment rate spikes to 100%.
- **Regulatory Exposure**:
  - **RBI Master Direction (2024)**: P1 incident reporting required within 2 hours; mandatory RTO < 4 hours (internal target: < 5 min).
  - **NPCI UPI Technical Standards**: Penalty of ₹5 Lakh per 15-minute outage; threat of temporary UPI participant routing de-prioritization.
  - **CERT-In Cybersecurity Guidelines**: Mandatory incident notification within 6 hours.

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Timestamp | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :---: | :--- | :--- | :--- | :--- |
| **1** | T + 00:10 | Acknowledge PagerDuty SEV-1 Alert | Incident Commander | PagerDuty Mobile App / CLI `pd incident ack` | War room established; automated escalation halted |
| **2** | T + 00:20 | Join Emergency Out-of-Band War Room | All Roles | Dial Bridge: `+91-22-6988-0001` PIN `99281` (Out-of-band cellular bridge, bypasses Slack/Zoom) | Command triumvirate assembled (IC, DBA, SecLead) |
| **3** | T + 00:40 | Verify AWS Regional Status | Lead SRE | `aws health describe-events --region ap-south-1 --filter services=EC2,RDS,NETWORK` | Identifies whether outage is localized AWS AZ or broad Region |
| **4** | T + 01:00 | Confirm Mumbai Ingress Deadlock | Lead SRE | `curl -Iv --connect-timeout 5 https://api-mum.paysecure.in/health/deep` | Returns `Connection timed out` or `HTTP 503` |
| **5** | T + 01:20 | Check Hyderabad Standby Health | Lead SRE | `curl -Iv https://api-hyd.paysecure.in/health/ready` | Returns `HTTP 200 OK` (Standby EKS ready) |
| **6** | T + 01:40 | Verify Aurora Storage Replication Lag | Lead DBA | `aws cloudwatch get-metric-statistics --region ap-south-2 --namespace AWS/RDS --metric-name AuroraGlobalDBReplicationLag --dimensions Name=DBClusterIdentifier,Value=paysecure-secondary --period 60 --statistics Maximum --start-time $(date -u -d '5 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ)` | Lag confirmed < 1,000 ms prior to Mumbai blackout |
| **7** | T + 02:00 | Authorize Multi-Region Failover Gate | Incident Commander | Formal Verbal Gate: *"Execute RB-01 Failover to ap-south-2"* | Emergency protocol activated |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Timestamp | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :---: | :--- | :--- | :--- | :--- |
| **8** | T + 02:15 | Check Route 53 Health Check Observations | Lead SRE | `aws route53 get-health-check-status --health-check-id hc-mumbai-calculated-composite --query 'HealthCheckObservations[*].[Region,StatusReport.Status]' --output table` | All 8 global probing regions report `Unhealthy` |
| **9** | T + 02:30 | Verify EKS Hyderabad Node Capacity | Lead SRE | `kubectl --context paysecure-hyd get nodes -o wide` | 12 nodes confirmed `Ready` in `ap-south-2a/b/c` |
| **10** | T + 02:45 | Check DynamoDB Global Table Replication | Lead DBA | `aws dynamodb describe-table --table-name paysecure-idempotency-sessions --region ap-south-2 --query 'Table.Replicas[?RegionName==\`ap-south-2\`].ReplicaStatus'` | Status confirmed `ACTIVE` |
| **11** | T + 03:00 | Check MSK Hyderabad Consumer Offset Lag | Lead DBA | `aws kafka describe-cluster --cluster-arn $(aws kafka list-clusters --region ap-south-2 --query 'ClusterInfoList[0].ClusterArn' --output text) --region ap-south-2` | Cluster state confirmed `ACTIVE` |

---

## 6. Failover Procedure (5–15 Minutes / Target RTO: 3m 30s)
| Step # | Timestamp | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :---: | :--- | :--- | :--- | :--- |
| **12** | T + 03:10 | **DECISION BRANCH 1**: Evaluate Region Loss vs Partition | Incident Commander | *If Mumbai control plane completely dark -> Proceed to Step 13. If intermittent packet loss -> Verify split-brain fencing first.* | Path A chosen: Hard Regional Outage |
| **13** | T + 03:15 | Detach Hyderabad Aurora Cluster from Global Cluster | Lead DBA | `aws rds remove-from-global-cluster --region ap-south-2 --global-cluster-identifier paysecure-global --db-cluster-identifier arn:aws:rds:ap-south-2:123456789012:cluster:paysecure-secondary` | Detachment initiated; secondary begins standalone writer promotion |
| **14** | T + 03:30 | Monitor Aurora Promotion Completion | Lead DBA | `aws rds describe-db-clusters --region ap-south-2 --db-cluster-identifier paysecure-secondary --query 'DBClusters[0].[Status,Endpoint]' --output table` | Status transitions from `promoting` to `available` (~75s) |
| **15** | T + 03:45 | Update Kubernetes Database Internal DNS ConfigMap | Lead SRE | `kubectl --context paysecure-hyd -n paysecure patch configmap region-config --type merge -p '{"data":{"aurora-endpoint":"paysecure-secondary.cluster-xyz.ap-south-2.rds.amazonaws.com"}}'` | ConfigMap updated to new local writer endpoint |
| **16** | T + 04:00 | Rapid Scale-Up of EKS Compute Fleet | Lead SRE | `kubectl --context paysecure-hyd -n paysecure scale deployment payment-api --replicas=36 && kubectl --context paysecure-hyd -n paysecure scale deployment transaction-processor --replicas=48 && kubectl --context paysecure-hyd -n paysecure scale deployment settlement-engine --replicas=16` | Kubernetes schedules pods across all 3 AZs in Hyderabad |
| **17** | T + 04:15 | Promote ElastiCache Global Datastore | Lead DBA | `aws elasticache failover-global-replication-group --region ap-south-2 --global-replication-group-id paysecure-redis-global --primary-region ap-south-2 --primary-replication-group-id paysecure-redis-hyd` | Redis cluster promoted to read-write primary in 25s |
| **18** | T + 04:30 | Trigger Route 53 Forced DNS Inversion | Lead SRE | `aws route53 change-resource-record-sets --hosted-zone-id Z1234567890 --change-batch file://configs/route53-force-hyd.json` | Mumbai ALB record disabled; Hyderabad ALB receives 100% DNS queries |
| **19** | T + 04:45 | Execute Bank Tunnel Re-routing | Lead SRE | `aws ec2 enable-vgw-route-propagation --region ap-south-2 --route-table-id rtb-hyd-private-data --gateway-id vgw-hyd-bank-directconnect` | Direct Connect leased lines to HDFC, ICICI, SBI activated in Hyderabad |
| **20** | T + 05:00 | Validate Microservice Health Probes | Lead SRE | `kubectl --context paysecure-hyd -n paysecure get pods -l tier=backend | grep -v Running` | All pods confirmed `Running` (0 unready pods) |
| **21** | T + 05:15 | Execute Synthetic Test Payment | Lead SRE | `curl -X POST https://api.paysecure.in/api/v1/payments/test-probe -H "Authorization: Bearer $SYNTHETIC_KEY" -H "Content-Type: application/json" -d '{"amount":100,"currency":"INR","merchant_id":"M-TEST-DR"}'` | Returns `HTTP 200 OK` with transaction ID; auth confirmed |
| **22** | T + 05:30 | **DECISION BRANCH 2**: Verify Error Rate Gate | Incident Commander | *If synthetic test succeeds and 5xx < 0.1% -> Declare Failover Complete. If errors > 1% -> Enter Rollback / Escalation.* | Success verified. RTO achieved: 3 min 30s |

---

## 7. Communication Protocol
### Engineering Notification Template
```
Subject: [P1 CRITICAL] Regional Failover Executed: ap-south-1 -> ap-south-2 - Incident #PSG-20260912-01
Status: MITIGATED / FAILOVER COMPLETE
Impact: Complete outage of AWS Mumbai. Traffic shifted to Hyderabad Standby.
Affected Components: Core Payment API, Aurora DB, MSK, Redis.
Current Actions: Hyderabad promoted to primary read/write; synthetic payments passing.
ETA for Normal Operations: Serving 100% traffic from ap-south-2.
Incident Commander: Rajesh Mehta (CTO) / Priya Krishnan (CRO)
War Room: https://paysecure.bridge.telecom/war-room-01
```

### Merchant Advisory Notification Template
```
Subject: PaySecure Service Advisory: Traffic Successfully Shifted to Disaster Recovery Region
Dear Merchant Partner,
At 12:00 PM IST, our automated monitoring detected infrastructure degradation within our primary data center region (AWS Mumbai).
Our automated multi-region disaster recovery systems activated immediately, steering all transaction traffic to our fully synchronized Hyderabad facility within 3.5 minutes.
Current Status: All payment methods (UPI, Cards, NetBanking, Wallets) are fully operational.
Data Protection Guarantee: Zero transaction data loss occurred; all idempotency records were preserved across our dual-region fabric.
Support Line: +91-22-6988-0099 | status.paysecure.in
```

### Regulatory Notification Template (RBI & NPCI Mandatory Incident Report)
```
To: Chief General Manager, Department of Payment and Settlement Systems, Reserve Bank of India
From: PaySecure Gateway Private Limited (PPA License No: RBI/DPSS/2022-23/9812)
Subject: URGENT: Mandatory Incident Report under Section 34 of PSS Act 2007
Incident Classification: P1 - Catastrophic Regional Data Centre Event
Time of Detection: 12:00:15 IST
Nature of Incident: Complete loss of AWS ap-south-1 (Mumbai) regional infrastructure.
Impact on Services: Temporary gateway latency blip for 3 minutes 30 seconds.
Remediation Actions: Executed planned DR Runbook RB-01; detached and promoted Aurora PostgreSQL Global Database in ap-south-2 (Hyderabad); shifted Route 53 Anycast DNS.
Current Status: 100% transaction processing restored in Hyderabad at 12:03:45 IST.
Recovery Point Objective (RPO): < 650 ms (Zero committed payment records lost).
Recovery Time Objective (RTO): 3 Minutes 30 Seconds (Mandate: < 5 Minutes).
Data Localisation Compliance: 100% of data processing and storage remained strictly on Indian soil.
Contact Person: Anand Sharma, Head of Compliance | anand.sharma@paysecure.in | +91-98200-11223
```

---

## 8. Verification and Validation
1. **Endpoint Health Probes**:
   - `curl -s https://api.paysecure.in/health/ready` -> Must return `{"status":"READY","region":"ap-south-2"}`.
2. **Aurora Primary Writer Query**:
   ```sql
   SELECT inet_server_addr(), pg_is_in_recovery(), current_timestamp;
   -- pg_is_in_recovery() MUST return FALSE (confirming standalone writer mode)
   ```
3. **Grafana DR Readiness Dashboard**:
   - Verify panel `Payment API Success Rate (ap-south-2)` is `>= 99.8%`.
   - Verify panel `P99 Transaction Latency` is `<= 215 ms`.

---

## 9. Rollback Procedure (Controlled Failback to Mumbai)
*Note: Failback must ONLY be attempted during a scheduled maintenance window after AWS confirms Mumbai stability for >= 4 continuous hours.*
1. Confirm all 3 AZs in `ap-south-1` report healthy in AWS Health Dashboard.
2. Re-attach Mumbai Aurora cluster as a secondary replica to the newly authoritative Hyderabad writer:
   ```bash
   aws rds add-source-identifier-to-global-cluster --global-cluster-identifier paysecure-global --db-cluster-identifier arn:aws:rds:ap-south-1:123456789012:cluster:paysecure-mumbai
   ```
3. Allow storage replication lag from Hyderabad back to Mumbai to fall below 200 ms.
4. Gradually adjust Route 53 Weighted DNS: `90/10 -> 50/50 -> 10/90 -> 0/100` over 30 minutes.
5. Execute clean managed switchover:
   ```bash
   aws rds failover-global-cluster --global-cluster-identifier paysecure-global --target-db-cluster-identifier arn:aws:rds:ap-south-1:123456789012:cluster:paysecure-mumbai
   ```

---

## 10. Post-Incident Review (PIR) Checklist
- [ ] Reconstruct exact microsecond incident timeline using CloudWatch Logs Insights.
- [ ] Conduct 5-Whys Root Cause Analysis meeting with AWS Technical Account Manager.
- [ ] Run `scripts/failover/reconcile-split-brain.py` to audit transaction matching across both regions.
- [ ] File formal compliance dossier with RBI and NPCI within 24 hours.
- [ ] Submit insurance claim under Cyber & Business Interruption Policy for infrastructure surge costs.
