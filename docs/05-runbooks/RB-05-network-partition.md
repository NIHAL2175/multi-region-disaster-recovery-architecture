# PaySecure DR Runbook: RB-05 Network Partition Between Regions

## 1. Scenario Identification
- **Runbook ID**: RB-05
- **Scenario Name**: Inter-Region Network Partition (Severed Transit Link between Mumbai and Hyderabad)
- **Category**: Infrastructure / Distributed Systems Network Partition
- **Severity Classification**: P1 - Critical Split-Brain Risk
- **Target RTO**: Fencing < 60 Seconds; Partition Containment < 3 Minutes
- **Target RPO**: Zero Transaction Ledger Divergence (RPO = 0)
- **Affected Components**: AWS Transit Gateway Inter-Region Peering, Aurora Storage Replication, DynamoDB Global Table Sync, MSK Replicator, and Cross-Region Monitoring.
- **Incident Commander Role**: Principal Distributed Systems Architect / Lead SRE
- **Secondary Roles**: Lead DBA, Network Engineer, Chief Risk Officer

---

## 2. Detection Mechanism
1. **Transit Gateway Peer Packet Drop Alert**: `TGWInterRegionPacketLossHigh`
   - Metric: `AWS/TransitGateway -> BytesDropCount` > 10,000 packets/min across peering attachment `tgw-attach-mum-hyd`.
2. **Replication Lag Multi-Tier Alert**: `CrossRegionReplicationSevered`
   - Prometheus Alert: `aurora_global_replication_lag_seconds > 5.0` AND `dynamodb_replication_latency_seconds > 5.0`.
3. **Heartbeat Quorum Loss**: `HeartbeatWitnessQuorumLoss`
   - CloudWatch Alarm on DynamoDB Heartbeat Table: Hyderabad region fails to renew monotonic lease within 5,000 ms.

---

## 3. Impact Assessment
- **Split-Brain Financial Exposure**: If both regions continue accepting writes independently, merchant balances diverge, resulting in potential double-spending and un-reconcilable nodal settlements.
- **Throughput Impact**: Latency-based routing could send clients to both regions simultaneously if Route 53 health checkers fail to detect internal partition.
- **Regulatory Liability**: RBI Master Direction Section 34 mandates zero data divergence during network disruptions.

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge Partition P1 Alert | Incident Commander | PagerDuty ACK on Incident `#PSG-NET-PARTITION` | Quorum War Room initiated |
| **2** | Isolate Hyderabad Write Paths (Automated Self-Fencing) | Lead SRE | Run `scripts/failover/enforce-fencing-hyd.sh` | Revokes write permissions in Hyderabad; forces read-only state |
| **3** | Invert Route 53 Health Status for Secondary Region | Network Eng | `aws route53 update-health-check --health-check-id hc-hyd-deep-secondary --inverted` | Route 53 drops Hyderabad from DNS; steers 100% traffic to Mumbai |
| **4** | Check Transit Gateway Peering Status | Network Eng | `aws ec2 describe-transit-gateway-peering-attachments --filters Name=state,Values=available,pending,failing` | Identifies whether link is `failing` or `degraded` |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Verify Authoritative Writer in Mumbai | Lead DBA | `SELECT pg_is_in_recovery();` on Mumbai Aurora | Returns `false` (Authoritative primary intact) |
| **6** | Verify Read-Only Mode on Hyderabad Aurora | Lead DBA | `SELECT pg_is_in_recovery();` on Hyderabad Aurora | Returns `true` (Confirming no rogue writes occurred) |
| **7** | Query DynamoDB Partition Key Leases | Lead DBA | `aws dynamodb get-item --table-name paysecure-heartbeat --key '{"partition_id":{"S":"GLOBAL_QUORUM"}}'` | Confirms Mumbai retains valid quorum token |
| **8** | Run Ping & Trace across TGW Peering | Network Eng | `mtr --report -c 50 10.200.1.5` (from Mumbai Bastion to Hyderabad Bastion) | Confirms 100% packet loss on direct inter-region fiber |

---

## 6. Partition Containment & Reconciliation Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **9** | **DECISION BRANCH 1**: True Partition vs Total Secondary Failure | Incident Commander | *If Mumbai is fully operational and healthy -> Keep Mumbai as 100% active; fence Hyderabad. If Mumbai degraded -> Promote Hyderabad.* | Mumbai is healthy (100% traffic maintained in Mumbai) |
| **10** | Apply Strict Local Firewall Fencing in Hyderabad | Lead SRE | `kubectl --context paysecure-hyd -n paysecure scale deployment payment-api --replicas=0` | Prevents any stray requests hitting Hyderabad pods |
| **11** | Monitor Transit Gateway Peering Recovery | Network Eng | `aws ec2 wait transit-gateway-peering-attachment-available --transit-gateway-attachment-ids tgw-attach-mum-hyd` | Waits for AWS fiber link restoration |
| **12** | Verify Network Link Latency Post-Restoration | Network Eng | `ping -c 100 10.200.1.5` | RTT returns to stable 15-20 ms (< 0.01% packet loss) |
| **13** | Check Aurora Global Database Catch-Up | Lead DBA | `aws cloudwatch get-metric-statistics --region ap-south-2 --namespace AWS/RDS --metric-name AuroraGlobalDBReplicationLag --period 60 --statistics Average --start-time $(date -u -d '5 minutes ago' +%FT%TZ) --end-time $(date -u +%FT%TZ)` | Storage replication catches up; lag drops < 500 ms |
| **14** | Re-sync DynamoDB Global Table Streams | Lead DBA | `aws dynamodb describe-table --table-name paysecure-idempotency-sessions --region ap-south-2 --query 'Table.Replicas'` | Replica status returns to `ACTIVE` |
| **15** | Flush & Restart MSK Replicator Connectors | Lead SRE | `aws kafka update-replication-state --replicator-arn $REPLICATOR_ARN --target-state RUNNING` | Cross-region Kafka consumer offsets re-synchronized |
| **16** | Re-scale Hyderabad Pre-Warmed Compute Fleet | Lead SRE | `kubectl --context paysecure-hyd -n paysecure scale deployment payment-api --replicas=12` | Standby compute restored to 30% baseline |
| **17** | Restore Route 53 Secondary Health Probes | Network Eng | `aws route53 update-health-check --health-check-id hc-hyd-deep-secondary --no-inverted` | Normal Route 53 health monitoring restored |

---

## 7. Communication Protocol
- **Engineering Comms**: `[P1 MITIGATED] Inter-region network partition detected and contained. Hyderabad fenced. Mumbai processed 100% traffic with zero ledger divergence.`
- **Executive Comms**: Sent to CRO and CTO confirming zero financial balance exposure.

---

## 8. Verification & Validation
- Run ledger audit script: `python scripts/failover/verify-ledger-consistency.py` -> Must confirm 0 orphan records.
- Check Route 53 DNS distribution: 100% queries resolving to Mumbai ALB.

---

## 9. Rollback Procedure
If fencing script locks out database connections in primary:
1. Revert security group changes via `aws ec2 authorize-security-group-ingress`.
2. Re-open listener rules on Mumbai ALB.

---

## 10. Post-Incident Review Checklist
- [ ] Review AWS Transit Gateway inter-region SLA with AWS Enterprise Support.
- [ ] Add secondary redundant IPsec VPN tunnel between Mumbai and Hyderabad as automated failover route for TGW.
- [ ] Log incident report with RBI Compliance committee.
