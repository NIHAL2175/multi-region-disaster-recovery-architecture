# PaySecure DR Runbook: RB-04 Kafka Cluster Failure

## 1. Scenario Identification
- **Runbook ID**: RB-04
- **Scenario Name**: Complete Amazon MSK Kafka Cluster Failure / ZooKeeper-Controller Quorum Loss
- **Category**: Infrastructure / Event Streaming
- **Severity Classification**: P1 - High Operational Emergency
- **Target RTO**: < 5 Minutes (Bypass Mode < 60s; Cluster Failover < 4m)
- **Target RPO**: < 1 Minute (Design Verification: Replicated in Hyderabad MSK)
- **Affected Components**: Amazon MSK Mumbai Cluster (`paysecure-msk-mumbai`, 6 brokers), topics `payment-events`, `settlement-triggers`, `webhook-deliveries`, and `audit-log-events`.
- **Incident Commander Role**: Principal Platform Engineer
- **Secondary Roles**: Lead Data Engineer, Settlement Operations Lead, Merchant Webhook SRE

---

## 2. Detection Mechanism
1. **Broker Under-Replicated Partitions Alert**: `MSKUnderReplicatedPartitionsHigh`
   - Metric: `AWS/Kafka -> UnderReplicatedPartitions > 10` for 2 minutes.
2. **Kafka Producer Error Spike**: `PaymentApiKafkaDispatchFailure`
   - Metric: `paysecure_kafka_producer_failed_total > 50 errors/min`.
3. **Consumer Lag Explosion**: `SettlementEngineConsumerLagHigh`
   - Prometheus Alert: `kafka_consumergroup_lag{topic="payment-events"} > 100000`.

---

## 3. Impact Assessment
- **Settlement & Reconciliation Stoppage**: Asynchronous settlement jobs blocked; merchant payout batches cannot be calculated.
- **Webhook Outage**: Webhook deliveries to 45,000 merchant endpoints stall; merchants cannot confirm transaction status asynchronously.
- **Core Authorization Impact**: If unmitigated, `payment-api` threads block waiting for Kafka producer acknowledgments, exhausting connection pools within 90 seconds.

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge Kafka SEV-1 Alert | Platform Lead | PagerDuty ACK on Incident `#PSG-MSK-FAIL` | PagerDuty incident acknowledged |
| **2** | Activate Emergency Queue Bypass Mode | Platform Lead | `kubectl -n paysecure patch configmap region-config --type merge -p '{"data":{"KAFKA_BYPASS_MODE":"true"}}'` | `payment-api` writes critical events directly to Aurora emergency table `event_fallback_buffer` (Bypasses Kafka producer timeout) |
| **3** | Check MSK Broker States | Data Eng | `aws kafka describe-cluster --cluster-arn $MSK_MUM_ARN --query 'ClusterInfo.State'` | Confirms whether cluster is `FAILED` or `REBOOTING_BROKERS` |
| **4** | Inspect EBS Disk Utilization | Data Eng | `aws cloudwatch get-metric-statistics --namespace AWS/Kafka --metric-name KafkaDataLogsDiskUsed --dimensions Name=ClusterArn,Value=$MSK_MUM_ARN --period 60 --statistics Maximum` | Identifies if disk saturation caused broker crash |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Test Kafka Cluster Connectivity | Data Eng | `kcat -b $MSK_MUM_BOOTSTRAP -L` | Returns broker connection timeout or metadata error |
| **6** | Verify Hyderabad Standby MSK Cluster | Data Eng | `kcat -b $MSK_HYD_BOOTSTRAP -L` | Returns all topics online with 6 healthy brokers |
| **7** | Query Event Fallback Buffer Table in Aurora | Lead DBA | `SELECT count(*) FROM event_fallback_buffer WHERE processed = false;` | Verifies incoming transactions are safely staging in Aurora during bypass |

---

## 6. Failover & Recovery Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **8** | **DECISION BRANCH 1**: Local Broker Reboot vs Cross-Region Failover | Platform Lead | *If 1 broker down -> Reboot broker. If >= 3 brokers down or controller quorum lost -> Shift streaming to Hyderabad MSK.* | Quorum lost -> Shift event publishing to Hyderabad MSK |
| **9** | Re-point Application Kafka Bootstrap Endpoints | Platform Lead | `kubectl -n paysecure patch configmap region-config --type merge -p "{"data":{"KAFKA_BOOTSTRAP_SERVERS":"$MSK_HYD_BOOTSTRAP"}}"` | EKS microservices re-targeted to Hyderabad MSK |
| **10** | Rolling Restart of Payment Processing Pods | Platform Lead | `kubectl -n paysecure rollout restart deployment transaction-processor settlement-engine webhook-dispatcher` | Pods establish TLS connections to Hyderabad MSK brokers |
| **11** | Disable Queue Bypass Mode | Platform Lead | `kubectl -n paysecure patch configmap region-config --type merge -p '{"data":{"KAFKA_BYPASS_MODE":"false"}}'` | Direct Kafka publishing resumes to Hyderabad cluster |
| **12** | Trigger Fallback Buffer Drain Worker | Data Eng | `kubectl -n paysecure create job --from=cronjob/fallback-drain-worker fallback-drain-manual-$(date +%s)` | Replays buffered events from Aurora into Hyderabad Kafka |
| **13** | Monitor Consumer Lag on Hyderabad MSK | Data Eng | `kafka-consumer-groups.sh --bootstrap-server $MSK_HYD_BOOTSTRAP --group settlement-processor --describe` | Lag steadily decreases to < 500 messages |
| **14** | Restart Webhook Dispatcher Fleet | Platform Lead | `kubectl -n paysecure scale deployment webhook-dispatcher --replicas=32` | Accelerated webhook processing clears backlog |

---

## 7. Communication Protocol
- **Engineering Comms**: `MSK Mumbai failed. Bypass activated. Event publishing successfully shifted to Hyderabad MSK cluster. Backlog draining.`
- **Merchant Advisory**: `Merchant webhook notifications experienced a brief 4-minute queuing delay; all missed webhooks are being re-dispatched.`

---

## 8. Verification & Validation
- Check producer throughput in Hyderabad: `rate(paysecure_kafka_producer_success_total[1m]) > 800 msgs/sec`.
- Verify zero records remaining in `event_fallback_buffer`.

---

## 9. Rollback Procedure
1. Rebuild or reboot failed Mumbai MSK brokers via `aws kafka reboot-broker`.
2. Sync topics from Hyderabad back to Mumbai via MSK Replicator.
3. Switch bootstrap configuration back during maintenance window.

---

## 10. Post-Incident Review Checklist
- [ ] Expand broker storage volume auto-scaling thresholds from 85% to 75%.
- [ ] Transition MSK cluster to Apache Kafka 3.6+ with KRaft mode (removing ZooKeeper dependency).
- [ ] Add automated circuit breaker testing to Chaos Engineering schedule.
