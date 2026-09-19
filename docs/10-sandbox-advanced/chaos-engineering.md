# PaySecure Gateway: Chaos Engineering Experiment Specification for DR Validation

**Document ID**: PSG-CHAOS-001  
**Framework**: Chaos Mesh / AWS Fault Injection Simulator (FIS)  
**Safety Protocol**: Automated Canary Abort Gates & Blast Radius Controls  

---

## 1. Principles of Chaos Engineering in Regulated Payment Gateways

Conducting chaos experiments on financial transaction infrastructure processing ₹500 crore daily requires rigorous blast radius boundaries to prevent accidental transaction degradation or merchant ledger imbalances. PaySecure adheres to four foundational rules:
1. **Never Inject Chaos during Festival Windows or Peak Business Hours**: Experiments execute exclusively during low-traffic windows (Tuesday 02:00 - 04:00 AM IST).
2. **Automated Abort Gates**: CloudWatch synthetic probes continuously measure transaction error rates. If 5xx errors exceed 0.1% or P99 latency exceeds 350 ms, the experiment halts and rolls back automatically within 5 seconds.
3. **Synthetic Tenant Quarantining**: 80% of chaos tests run against dedicated synthetic merchant accounts (`M-CHAOS-TEST-xxx`) processing real sandbox bank transactions.

---

## 2. Six Mandatory Chaos Engineering Experiments

```
+-------------------------------------------------------------------------------------------------------------------------------+
| PaySecure Master Chaos Engineering Experiment Matrix                                                                          |
+---+--------------------+--------------------------------+--------------------+-------------------------+----------------------+
| # | Experiment Name    | Core Hypothesis Tested         | Injected Fault     | Blast Radius Control    | Automated Abort Gate |
+---+--------------------+--------------------------------+--------------------+-------------------------+----------------------+
| 1 | EKS Worker Node    | Pods reschedule within 30s;    | Terminate random   | Single EC2 node in      | 5xx Error Rate > 0.1%|
|   | Abrupt Termination | zero transaction failures      | EC2 node instance  | ap-south-1a (PDB: 75%)  | for > 15 seconds     |
+---+--------------------+--------------------------------+--------------------+-------------------------+----------------------+
| 2 | Aurora Writer      | Application connection pool    | tc / netem injects | Single writer database  | P99 Transaction      |
|   | Network Latency    | fails over to read replicas    | 200 ms latency     | network interface (eth0)| Latency > 450 ms     |
+---+--------------------+--------------------------------+--------------------+-------------------------+----------------------+
| 3 | Inter-Region Fiber | Cross-region monitoring trips  | iptables DROP rule | Cross-region TGW route  | Replication Lag      |
|   | Severance          | P1 alarm within 30 seconds     | on TGW port 443    | (5-minute max duration) | > 5 Minutes          |
+---+--------------------+--------------------------------+--------------------+-------------------------+----------------------+
| 4 | Route 53 Health    | DNS failover steers 100%       | Inject HTTP 503 on | Deep health probe       | Client-visible       |
|   | Inversion Test     | traffic to Hyderabad in < 3.5m | /health/deep       | endpoint only           | errors > 0.05%       |
+---+--------------------+--------------------------------+--------------------+-------------------------+----------------------+
| 5 | Kafka Broker Disk  | Consumer failover maintains    | Corrupt / fill disk| Single Kafka broker     | Consumer Group Lag   |
|   | Saturation         | ordered stream processing      | via dd block write | EBS volume in ap-south-1b| > 50,000 messages   |
+---+--------------------+--------------------------------+--------------------+-------------------------+----------------------+
| 6 | Database Secret    | Application refreshes credentials| Revoke IAM secret | Single staging database | Transaction Failure  |
|   | Sudden Revocation  | via Secrets Manager in < 60s   | version in Secrets | credentials version     | Rate > 0.5%          |
+---+--------------------+--------------------------------+--------------------+-------------------------+----------------------+
```

### Experiment Deep-Dive: Experiment 3 (Inter-Region Replication Severance)
- **Objective**: Validate that a sudden network severed link between Mumbai and Hyderabad does not trigger split-brain double-writing.
- **Fault Injection Command (via AWS FIS)**:
  ```bash
  aws fis start-experiment --experiment-template-id exp-tgw-partition-simulate
  ```
- **Observed Behavior**: Route 53 health checks detect the cross-region lag increase; Hyderabad automated self-fencing script executes within 45 seconds; Mumbai continues as 100% authoritative writer with zero ledger divergence.
