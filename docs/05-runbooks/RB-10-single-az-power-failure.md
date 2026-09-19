# PaySecure DR Runbook: RB-10 Single AZ Power Failure

## 1. Scenario Identification
- **Runbook ID**: RB-10
- **Scenario Name**: Complete Data Centre Power / Cooling Failure in Availability Zone `ap-south-1a`
- **Category**: Infrastructure / Localized Physical Failure
- **Severity Classification**: P2 - High Availability Degradation (Multi-AZ Resilient)
- **Target RTO**: Automatic AZ Failover < 90 Seconds (Zero Human Intervention Required)
- **Target RPO**: Zero Transaction Loss (RPO = 0)
- **Affected Components**: 8 EKS worker nodes in `ap-south-1a`, Aurora Primary Writer (if located in 1a), 2 MSK Kafka brokers, 1 NAT Gateway, and 1 ElastiCache shard replica.
- **Incident Commander Role**: Primary Platform SRE On-Call
- **Secondary Roles**: Lead DBA, Kubernetes Cluster Administrator

---

## 2. Detection Mechanism
1. **EKS Node NotReady Spike**: `EKSNodeNotReadySevere`
   - Prometheus Alert: `sum(kube_node_status_condition{condition="Ready",status="false"}) >= 8` for 1 minute.
2. **Aurora Writer Failover Event**: `RDSDBInstanceFailoverCompleted`
   - AWS RDS Event: `RDS-EVENT-0049` (A Multi-AZ failover has completed for Aurora cluster `paysecure-primary`).
3. **AWS Personal Health Dashboard Notification**: Power degradation advisory for `ap-south-1a`.

---

## 3. Impact Assessment
- **Compute Capacity Loss**: Approximately 33% of EKS cluster compute capacity lost (8 of 24 nodes become unready).
- **Database Behavior**: Aurora automatically fails over to reader replica in `ap-south-1b` or `ap-south-1c` within 60 to 120 seconds.
- **Regional Continuity**: Cross-region failover to Hyderabad is **NOT required**; local Multi-AZ architecture absorbs the impact!

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge Multi-AZ Failure Alert | Platform SRE | PagerDuty ACK on Incident `#PSG-AZ-POWER-1A` | Incident triage underway |
| **2** | Verify Aurora Multi-AZ Writer Failover | Lead DBA | `aws rds describe-db-clusters --db-cluster-identifier paysecure-primary --query 'DBClusters[0].[Status,WriterClusterEndpoint]'` | Confirms writer promoted in `ap-south-1b` |
| **3** | Inspect Kubernetes Pod Rescheduling | Platform SRE | `kubectl get nodes -l topology.kubernetes.io/zone=ap-south-1a` | Confirms nodes marked `NotReady` |
| **4** | Check PodDisruptionBudget Constraints | Platform SRE | `kubectl get pdb -n paysecure` | PDBs ensure minimum 75% pod availability across remaining AZs |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Monitor EKS Cluster Autoscaler Behavior | Platform SRE | `kubectl -n kube-system logs -l app=cluster-autoscaler --tail=50` | Autoscaler dynamically provisions replacement nodes in `1b` and `1c` |
| **6** | Check MSK Kafka Partition Under-Replication | Platform SRE | `kafka-topics.sh --bootstrap-server $MSK_BOOTSTRAP --describe --under-replicated-partitions` | ISR drops from 3 to 2; all partitions remain writable (`min.insync.replicas=2`) |
| **7** | Validate NAT Gateway Traffic Redistribution | Platform SRE | `aws ec2 describe-nat-gateways --filter Name=state,Values=available` | NAT Gateways in `1b` and `1c` handle egress without packet loss |

---

## 6. Self-Healing & Capacity Rebalancing Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **8** | Cordon Failed Availability Zone in Kubernetes | Platform SRE | `kubectl cordon -l topology.kubernetes.io/zone=ap-south-1a` | Prevents pods from scheduling on dying nodes |
| **9** | Evict Terminated Pods | Platform SRE | `kubectl delete pods -n paysecure --field-selector spec.nodeName=ip-10-100-10-xxx.ap-south-1.compute.internal --force --grace-period=0` | Reschedules pods onto healthy nodes in `1b` and `1c` |
| **10** | Expand Node Group Size in Surviving AZs | Platform SRE | `aws eks update-nodegroup-config --cluster-name paysecure-mumbai-prod --nodegroup-name ng-app-tier --scaling-config minSize=16,maxSize=32,desiredSize=24` | 8 replacement nodes join cluster in `1b` and `1c` within 3 minutes |
| **11** | Verify Application Transaction Success Rate | Platform SRE | `sum(rate(http_requests_total{status="200"}[2m])) / sum(rate(http_requests_total[2m]))` | Success rate rebounds to `>= 99.8%` |
| **12** | Confirm Aurora Write Latency | Lead DBA | `aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name CommitLatency --dimensions Name=DBClusterIdentifier,Value=paysecure-primary --period 60 --statistics Average` | Commit latency settles back to ~10 ms |

---

## 7. Communication Protocol
- **Internal Advisory**: `[P2 MITIGATED] Power loss in ap-south-1a absorbed by Multi-AZ infrastructure. Zero cross-region failover needed.`
- **Merchant Advisory**: None required (no external merchant disruption occurred).

---

## 8. Verification & Validation
- Check 0 pending pods: `kubectl get pods -n paysecure | grep Pending` -> Returns `0`.
- Verify Aurora cluster topology: 1 writer in `1b`, 1 reader in `1c`.

---

## 9. Rollback Procedure (Post-Power Restoration)
When AWS restores power to `ap-south-1a`:
1. Uncordon nodes in `1a`: `kubectl uncordon -l topology.kubernetes.io/zone=ap-south-1a`.
2. Provision replacement Aurora reader replica in `1a`.

---

## 10. Post-Incident Review Checklist
- [ ] Verify that cross-AZ data transfer billing conforms to projected cost allocation.
- [ ] Ensure that Kubernetes Descheduler rebalances pods evenly across all three AZs.
