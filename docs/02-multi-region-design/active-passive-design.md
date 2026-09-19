# PaySecure Gateway: Active-Passive (Hot Standby) Multi-Region Architecture Design

**Document ID**: PSG-ARCH-002-AP  
**Topology**: Dual-Region Active-Passive (Hot Standby)  
**Primary Region**: AWS `ap-south-1` (Mumbai, India)  
**Secondary Standby Region**: AWS `ap-south-2` (Hyderabad, India)  
**Target RTO**: < 5 Minutes (Design Target: 3 Minutes 30 Seconds)  
**Target RPO**: < 1 Minute (Design Target: Storage lag < 1.0 Second)  
**Classification**: Strictly Confidential - Payment Core Architecture  

---

## 1. Executive Summary & Strategic Rationale

Under the mandate of the **Reserve Bank of India (RBI Master Direction 2024)** and **NPCI UPI Technical Standards**, PaySecure Gateway Private Limited must transition from a vulnerable single-region deployment in Mumbai to a highly resilient multi-region disaster recovery architecture capable of surviving catastrophic regional failures.

This document details the **Active-Passive (Hot Standby)** deployment model between **AWS Mumbai (`ap-south-1`)** and **AWS Hyderabad (`ap-south-2`)**. In this architectural pattern:
- The **Primary Region (`ap-south-1`)** actively handles 100% of merchant production traffic, processing all 3.2 million daily transactions across credit cards, debit cards, net banking, and UPI rails.
- The **Secondary Region (`ap-south-2`)** operates as a synchronized "Hot Standby" environment. The EKS compute clusters are pre-provisioned and continuously running with minimal baseline pod replicas (30% capacity), stateful databases (Aurora PostgreSQL Global Database, DynamoDB Global Tables, and ElastiCache Global Datastore) are continuously replicating data across the AWS inter-region private backbone, and Amazon Route 53 health check probes actively monitor both regional endpoints.
- Upon automated or operator-confirmed failover initiation, client ingress is dynamically steered to Hyderabad, compute pods autoscale to 100% capacity in under 90 seconds, Aurora PostgreSQL is promoted to primary writer, and transaction processing resumes without split-brain anomalies or duplicate settlements.

---

## 2. Region Selection Rationale & Data Sovereignty

### 2.1 Why Mumbai (`ap-south-1`) and Hyderabad (`ap-south-2`)?
Selecting the optimal disaster recovery region for an Indian payment aggregator is governed by three non-negotiable vectors: network latency budget, seismic/geopolitical separation, and statutory data residency mandates.

```
+---------------------------------------------------------------------------------------------------+
| AWS Inter-Region Network Latency & Compliance Matrix                                              |
+--------------------------+-----------------------+---------------------+--------------------------+
| Region Pair              | Round-Trip Time (RTT) | Seismic / Grid Risk | RBI Data Localisation    |
+--------------------------+-----------------------+---------------------+--------------------------+
| Mumbai <-> Hyderabad     | 15 - 25 ms            | Low Correlation     | 100% Fully Compliant     |
| (ap-south-1 / ap-south-2)| (AWS Direct Backbone) | (Zone III vs II)    | (Domestic Sovereign Soil)|
+--------------------------+-----------------------+---------------------+--------------------------+
| Mumbai <-> Singapore     | 55 - 80 ms            | Negligible          | VIOLATION unless purged  |
| (ap-south-1 / southeast-1| (Subsea Cable Hop)    | Correlation         | within 24 hours (RBI)    |
+--------------------------+-----------------------+---------------------+--------------------------+
| Mumbai <-> Frankfurt     | 110 - 135 ms          | Zero                | EXPLICIT VIOLATION       |
| (ap-south-1 / central-1) | (Trans-Continental)   | Correlation         | (Cross-Border Transfer)  |
+--------------------------+-----------------------+---------------------+--------------------------+
```

1. **Ultra-Low Inter-Region Latency (15–25 ms RTT)**:
   - The physical network distance between Mumbai (Maharashtra) and Hyderabad (Telangana) is approximately 710 km. AWS operates dedicated, private 100 Gbps dark fiber inter-region transit links connecting `ap-south-1` and `ap-south-2`.
   - Measured round-trip ping latency hovers consistently between 15.2 ms and 21.8 ms (P99 < 25 ms).
   - This low latency is essential: storage-level asynchronous replication in Aurora Global Database incurs under 1 second of replication lag, while DynamoDB Global Tables replicate changes within 450 to 800 ms.
2. **Regulatory Compliance (RBI 2018 Data Localisation Mandate)**:
   - The RBI Circular on *Storage of Payment System Data* (DPSS.CO.OD No. 2785/06.08.005/2017-18) explicitly directs: *"All system providers shall ensure that the entire data relating to payment systems operated by them are stored in a system only in India."*
   - By anchoring both Primary and Secondary sites within Indian borders (`ap-south-1` and `ap-south-2`), PaySecure guarantees that cardholder data (CHD), transaction metadata, merchant banking credentials, and audit logs never cross international borders during normal operations, disaster events, or background backup replication.
3. **Tertiary Region Analysis (Singapore `ap-southeast-1`)**:
   - While Singapore was evaluated as a possible tertiary tier for compute-only burst capacity, cross-border regulatory liabilities under the Digital Personal Data Protection Act 2023 (DPDPA) and Section 43A of the IT Act 2000 make storing or replicating persistent financial records in Singapore legally precarious. The RBI allows overseas processing only on the condition that data returns to India within 24 hours and is permanently deleted from overseas systems. Given the operational overhead and risk of audit failure, Singapore is rejected for stateful persistence.

---

## 3. Detailed Topology & Traffic Flow Architecture

```
                                  [ DNS Entry: api.paysecure.in ]
                                                 │
                                                 ▼
                       [ AWS Route 53 DNS Failover Routing Policy ]
                         - TTL: 30 Seconds
                         - Primary: Mumbai ALB Alias (EvaluateTargetHealth = True)
                         - Secondary: Hyderabad ALB Alias (EvaluateTargetHealth = True)
                                                 │
                       ┌─────────────────────────┴─────────────────────────┐
                       │ (Active Path: 100% Traffic)                       │ (Standby Path: 0% Normal)
                       ▼                                                   ▼
         [ Primary Region: ap-south-1 ]                       [ Standby Region: ap-south-2 ]
         [ Internet-facing ALB + WAFv2]                       [ Internet-facing ALB + WAFv2]
                       │                                                   │
                       ▼                                                   ▼
         [ EKS: paysecure-mumbai-prod ]                       [ EKS: paysecure-hyd-standby ]
         (180 Pods Running / 100% Load)                       (60 Pods Pre-warmed / Standby)
                       │                                                   │
         ┌─────────────┼──────────────┐                                    │
         ▼             ▼              ▼                                    │
    [payment-api] [txn-processor] [cde-token]                              │
         │             │              │                                    │
         ▼             │              ▼                                    │
   [DynamoDB Table]    │       [KMS Multi-Region Primary]                  │
  (paysecure-sessions) │       (mrk-cde-mumbai-master)                     │
         │             │              │                                    │
         │ (Global Table Replic.)     │ (Replica Key)                      │
         │ < 800ms     │              │                                    │
         ▼             │              ▼                                    │
  [DynamoDB Table]     │       [KMS Replica Key]                           │
  (paysecure-sessions) │       (mrk-cde-hyd-replica)                       │
                       │                                                   │
                       ▼                                                   ▼
        [Aurora Global DB: Writer]    ───────────────►    [Aurora Global DB: Reader Cluster]
        (db.r6g.2xlarge in Mumbai)    Storage-Level Async (db.r6g.2xlarge in Hyderabad)
        [2 Reader Replicas in AZs]     Replication < 1s   [1 Reader Instance in AZ 2a]
                       │                                                   │
                       ▼                                                   ▼
        [ElastiCache Primary Group]   ───────────────►    [ElastiCache Secondary Global]
        (3 Shards / Redis 7.1)        Async Replication   (3 Shards Read-Only in Hyd)
                       │                                                   │
                       ▼                                                   ▼
        [Amazon MSK Mumbai Cluster]   ───────────────►    [Amazon MSK Hyderabad Cluster]
        (6 Brokers / 50k msgs/sec)    MSK Replicator Sync (6 Brokers / Standby)
```

### 3.1 Primary Region Components (`ap-south-1` Mumbai)
- **Ingress & Perimeter Security**: Dual-zone AWS Application Load Balancers with AWS WAFv2 inspecting SQLi, XSS, rate-limiting rules, and AWS Shield Advanced DDoS protection.
- **Compute Fleet**: Amazon EKS v1.28 cluster `paysecure-mumbai-prod` consisting of 24 worker nodes (`m6i.2xlarge`). Pods for all 12 microservices run at full production scale: `payment-api` (18 pods), `transaction-processor` (24 pods), `tokenisation-service` (8 pods), `settlement-engine` (8 pods), etc.
- **Transactional Persistence**: Aurora PostgreSQL 15.4 cluster with one writer instance (`db.r6g.2xlarge`) in `ap-south-1a` and two reader replicas in `ap-south-1b` and `ap-south-1c`.
- **Session & Idempotency Store**: DynamoDB table configured as an AWS Global Table with provisioned auto-scaling (10,000 RCU / 5,000 WCU).
- **In-Memory Cache**: ElastiCache Redis 7.1 cluster mode enabled (3 shards, 6 nodes).
- **Streaming Tier**: Amazon MSK Kafka cluster with 6 brokers processing up to 50,000 messages/sec.

### 3.2 Standby Region Components (`ap-south-2` Hyderabad)
- **Ingress**: Identical Application Load Balancer and WAFv2 rule sets provisioned via Terraform.
- **Pre-Warmed Compute Fleet**: Amazon EKS cluster `paysecure-hyd-standby` consisting of 12 worker nodes (`m6i.2xlarge`) running approximately 60 pods across all 12 microservices. Deployments maintain 30% baseline pod count to eliminate cold-start container pulling delays and ensure immediate readiness.
- **Database Standby**: Secondary Aurora cluster attached to `paysecure-global`. Storage-level replication continuously streams write-ahead logs (WAL) from Mumbai storage nodes to Hyderabad storage nodes without touching compute. One read replica (`db.r6g.2xlarge`) is running in Hyderabad to facilitate immediate writer promotion.
- **Cache Standby**: ElastiCache Redis Global Datastore secondary replication group running in read-only mode, actively receiving asynchronous updates from Mumbai.
- **Streaming Standby**: MSK Kafka cluster running in Hyderabad with AWS MSK Replicator synchronizing core topics (`payment-events`, `settlement-triggers`, `audit-log-events`).

---

## 4. Component-by-Component Failover & Warm-Up Sequence

In the event of a catastrophic primary region failure in Mumbai, the failover sequence executes across four synchronized phases to restore 100% transaction processing within **3 minutes and 30 seconds**.

```
+---------------------------------------------------------------------------------------------------+
| Active-Passive Failover Execution Timeline (Total Expected RTO: 3 min 30 sec)                    |
+--------------------+---------------------------------------------------------------+--------------+
| Elapsed Time       | Automated / Orchestrated Engineering Action                   | Owner        |
+--------------------+---------------------------------------------------------------+--------------+
| T = 00:00 to 00:30 | Multi-tier Route 53 Health Checks report 3 consecutive fails. | Automated    |
|                    | P1 CloudWatch alarm triggers Incident Commander & SRE pager.   | Monitoring   |
+--------------------+---------------------------------------------------------------+--------------+
| T = 00:30 to 01:00 | Incident Commander validates hard regional loss via AWS Health| Incident     |
|                    | Dashboard; confirms failover execution.                       | Commander    |
+--------------------+---------------------------------------------------------------+--------------+
| T = 01:00 to 02:15 | Automated Orchestrator triggers Aurora Secondary Promotion:   | Failover     |
|                    | aws rds remove-from-global-cluster (detach & promote to read/ | Script / SRE |
|                    | write). Database promotion completes in ~75 seconds.          |              |
+--------------------+---------------------------------------------------------------+--------------+
| T = 01:30 to 02:45 | EKS Cluster Autoscaler & HPA triggered in Hyderabad:          | Kubernetes   |
|                    | Node group scales from 12 to 24 nodes; pods scale 60 -> 180.  | HPA / SRE    |
+--------------------+---------------------------------------------------------------+--------------+
| T = 02:15 to 02:45 | ElastiCache Global Datastore promotes Hyderabad replica to    | Failover     |
|                    | primary read/write cluster via CLI promote command.           | Script / SRE |
+--------------------+---------------------------------------------------------------+--------------+
| T = 02:45 to 03:15 | Route 53 DNS Failover activates: primary health check status  | Route 53     |
|                    | set to UNHEALTHY. Ingress traffic begins routing to Hyderabad.| DNS Edge     |
+--------------------+---------------------------------------------------------------+--------------+
| T = 03:15 to 03:30 | Synthetic end-to-end payment test runs in Hyderabad;          | Health       |
|                    | 100% production traffic successfully served from ap-south-2.  | Monitor Pod  |
+--------------------+---------------------------------------------------------------+--------------+
```

### 4.1 Aurora PostgreSQL Promotion Procedure
In an unplanned regional disaster where Mumbai is completely unreachable, managed failover cannot coordinate with the failed writer. The secondary cluster must be detached and promoted:
```bash
# Execute emergency detachment of Hyderabad cluster from Global Database
aws rds remove-from-global-cluster   --region ap-south-2   --global-cluster-identifier paysecure-global   --db-cluster-identifier arn:aws:rds:ap-south-2:123456789012:cluster:paysecure-hyd-cluster

# Verify writer promotion status
aws rds describe-db-clusters   --region ap-south-2   --db-cluster-identifier paysecure-hyd-cluster   --query 'DBClusters[0].Status' --output text
```
Upon completion of this command (~75 seconds), the Hyderabad cluster becomes an autonomous read-write PostgreSQL cluster. Kubernetes internal DNS (`aurora-rw.paysecure.internal`) resolves immediately to the new local writer endpoint.

### 4.2 ElastiCache Redis Promotion
```bash
# Failover ElastiCache Global Datastore to Hyderabad
aws elasticache failover-global-replication-group   --region ap-south-2   --global-replication-group-id paysecure-redis-global   --primary-region ap-south-2   --primary-replication-group-id paysecure-redis-hyd
```
The secondary Redis cluster transitions from read-only replica to full read-write primary, accepting rate-limiting increments and merchant session cache writes.

### 4.3 EKS Compute Rapid Scaling
Because the standby EKS cluster is pre-warmed with 12 active worker nodes and 60 running pods, critical payment microservices are already scheduled and connected to the database read-replica. Upon failover trigger:
```bash
# Trigger immediate pre-emptive pod scale-up across critical services
kubectl --context paysecure-hyd -n paysecure scale deployment payment-api --replicas=36
kubectl --context paysecure-hyd -n paysecure scale deployment transaction-processor --replicas=48
kubectl --context paysecure-hyd -n paysecure scale deployment rate-limiter --replicas=24
```
The AWS Cluster Autoscaler provisions additional `m6i.2xlarge` EC2 instances across `ap-south-2a`, `ap-south-2b`, and `ap-south-2c`, reaching full 24-node capacity within 90 seconds.

---

## 5. In-Flight Transaction Handling & Settlement Integrity

One of the greatest dangers in disaster recovery failover is the ambiguous state of transactions that were initiated in Mumbai immediately prior to regional failure. PaySecure implements strict idempotency and settlement rules:

1. **Client-Side Idempotency Keys**:
   - Every merchant payment request must include an `Idempotency-Key` header composed of `SHA-256(merchant_id + order_id + amount)`.
   - Before executing authorization against card networks or NPCI UPI, the `payment-api` writes the idempotency record to DynamoDB Global Tables.
   - Because DynamoDB Global Tables replicate across Mumbai and Hyderabad in under 800 ms, transactions initiated in Mumbai are immediately visible to Hyderabad pods.
2. **Handling Mid-Flight Failures**:
   - If a merchant API request times out during the regional collapse, the merchant system automatically retries using the identical `Idempotency-Key`.
   - When the retried request reaches Hyderabad post-failover, `payment-api` inspects DynamoDB:
     - **Case A (Payment Committed in Mumbai & Replicated)**: The system detects the completed transaction status, avoids submitting a new charge, and immediately returns the successful payment receipt. **Zero double-charging occurs**.
     - **Case B (Payment Sent to NPCI/Bank but Unrecorded in Mumbai DB)**: The system queries NPCI / Acquiring Bank via the external UPI Verification API using the merchant order reference. If the bank confirmed debit, PaySecure updates Aurora in Hyderabad and credits the merchant. If the bank has no record, the transaction is safely processed afresh.
     - **Case C (Payment Never Left Gateway)**: Idempotency record shows `INITIATED` with expired lease; Hyderabad initiates a clean authorization workflow.

---

## 6. Failback Procedure: Returning to Primary Region (`ap-south-1`)

Once AWS confirms complete restoration and stability of the Mumbai region, failback must be executed methodically during a scheduled off-peak maintenance window (e.g., Sunday 03:00 AM IST) to prevent data loss or transaction disruption:

```
+---------------------------------------------------------------------------------------------------+
| PaySecure Failback Workflow (Controlled Off-Peak Transition)                                      |
+--------------------+---------------------------------------------------------------+--------------+
| Phase              | Operational Procedure                                         | Validation   |
+--------------------+---------------------------------------------------------------+--------------+
| 1. Sanity Check    | Verify all 3 AZs in ap-south-1 are fully operational; validate| CloudWatch / |
|                    | EKS node health and network connectivity.                     | AWS Health   |
+--------------------+---------------------------------------------------------------+--------------+
| 2. Reverse Sync    | Establish reverse Aurora Global Database replication:         | Replication  |
|                    | Set Hyderabad as primary writer; attach Mumbai as reader.     | Lag < 500ms  |
+--------------------+---------------------------------------------------------------+--------------+
| 3. Drain Traffic   | Shift Route 53 weighted DNS gradually: 90/10 -> 50/50 -> 0/100| Error Rate   |
|                    | from Hyderabad back to Mumbai over 15 minutes.                | < 0.01%      |
+--------------------+---------------------------------------------------------------+--------------+
| 4. Final Cutover   | Execute clean managed switchover: aws rds failover-global-    | Zero Data    |
|                    | cluster promoting Mumbai back to primary writer.              | Loss Verified|
+--------------------+---------------------------------------------------------------+--------------+
```

---

## 7. Operational Feasibility for an 8-Person SRE Team

A decisive advantage of the Active-Passive (Hot Standby) model is its realistic alignment with PaySecure's platform engineering capacity:
- **Simplified Operational Mental Model**: At any given second, there is exactly **one authoritative writer** for transactional data. Engineers on call never have to troubleshoot bi-directional replication race conditions, out-of-order Kafka partition conflicts, or split-brain ledger imbalances.
- **Predictable CI/CD Deployments**: Blue-Green deployments are applied to Mumbai first, verified against real traffic, and subsequently replicated to Hyderabad via GitOps (ArgoCD), guaranteeing zero configuration drift.
- **Sustainable On-Call Rotation**: 8 platform engineers support a 24/7 primary/secondary on-call rotation. The Hot Standby architecture incorporates automated health alerts and scripted runbooks that enable any engineer to execute failover in under 5 minutes without requiring senior DBA intervention.
