# PaySecure Gateway: Stateful Data Replication Strategy & Consistency Engineering

**Document ID**: PSG-DATA-001  
**Scope**: Multi-Region Replication Architecture across `ap-south-1` (Mumbai) and `ap-south-2` (Hyderabad)  
**Classification**: Strictly Confidential - Regulated Financial Data Architecture  
**Target RPO**: < 1 Minute (Design Target: < 1.0 Second for Transaction Ledgers)  
**Target RTO**: < 5 Minutes (Design Target: 3.5 Minutes)  

---

## 1. Architectural Principles & Consistency Framework

PaySecure Gateway processes **₹500 crore INR (~$60M USD)** daily across 3.2 million transactions. In financial infrastructure, data corruption or double-crediting cannot be remediated simply by server reboots. The stateful data replication strategy is founded upon four non-negotiable distributed systems principles:

1. **Deterministic Single-Source-of-Truth**: At any given millisecond, every merchant ledger account must have exactly one authoritative write coordinator to eliminate split-brain write conflicts.
2. **Asynchronous Storage Replication with Sub-Second Lag Bound**: Synchronous replication across regions separated by 700 km introduces an unavoidable 15–25 ms network round-trip penalty per commit. Because NPCI mandates end-to-end UPI latency under 300 ms, replication on the critical transaction write path must be asynchronous at the storage layer while maintaining replication lag strictly under 1,000 ms.
3. **Defense-in-Depth Idempotency Coordination**: All state transitions must be idempotent. Retried network calls caused by regional timeouts must never generate duplicate bank debits or merchant balance credits.
4. **Absolute Domestic Data Sovereignty**: In strict accordance with the **RBI Directive on Storage of Payment System Data (2018)**, all operational, replicated, and backup data remains confined to Indian borders (`ap-south-1` and `ap-south-2`).

---

## 2. Component-Specific Replication Engineering

```
+-------------------------------------------------------------------------------------------------------------------------------+
| Multi-Region Stateful Component Replication Matrix                                                                            |
+----------------------+--------------------------+-----------------------+---------------------+-------------------------------+
| Component            | Replication Technology   | Replication Mode      | Typical Lag Window  | Target Consistency Model      |
+----------------------+--------------------------+-----------------------+---------------------+-------------------------------+
| Aurora PostgreSQL    | Aurora Global Database   | Storage-Level Async   | 200 - 650 ms        | Strong in Primary; Eventual   |
| (Core Ledger & CDE)  | (Physical Storage Mirror)| (Dedicated AWS Fiber) | (P99 < 1,000 ms)    | in Secondary until Promoted   |
+----------------------+--------------------------+-----------------------+---------------------+-------------------------------+
| Amazon DynamoDB      | DynamoDB Global Tables   | Asynchronous          | 400 - 800 ms        | Strong Read (Local Region);   |
| (Idempotency/Session)| (Multi-Active Engine)    | (Active-Active Sync)  | (P99 < 1,200 ms)    | Eventual Read (Cross-Region)  |
+----------------------+--------------------------+-----------------------+---------------------+-------------------------------+
| ElastiCache Redis    | Global Datastore         | Asynchronous Engine   | 50 - 300 ms         | Read-Only Standby;            |
| (Rate Limiting/Cache)| (Cross-Region Mirroring) | (Non-Blocking Replication) (P99 < 800 ms)   | Eventual Consistency          |
+----------------------+--------------------------+-----------------------+---------------------+-------------------------------+
| Amazon MSK           | AWS MSK Replicator       | Asynchronous Event    | 500 - 2,500 ms      | At-Least-Once Delivery;       |
| (Kafka Event Streams)| (Managed MirrorMaker 2)  | Streaming (Offset Sync) (P99 < 5,000 ms)    | Ordered per Partition         |
+----------------------+--------------------------+-----------------------+---------------------+-------------------------------+
| Amazon S3            | S3 Cross-Region          | Asynchronous Object   | 1 - 3 Minutes       | Read-After-Write Consistency; |
| (Audit & Reports)    | Replication (CRR + RTC)  | Level (Encrypted KMS) | (SLA: < 15 Minutes) | Object Lock Compliance        |
+----------------------+--------------------------+-----------------------+---------------------+-------------------------------+
```

---

### 2.1 Amazon Aurora PostgreSQL (Core Financial Ledger & CDE)
- **Engine & Version**: Amazon Aurora PostgreSQL 15.4.
- **Mechanism Selection**: **Aurora Global Database**.
  Unlike traditional PostgreSQL physical streaming replication (which consumes database engine CPU to process write-ahead logs), Aurora Global Database replicates at the **distributed storage layer**. Storage fleets in Mumbai stream write blocks directly to storage fleets in Hyderabad over dedicated AWS backbone fiber, bypassing compute instances entirely.
- **Synchronous vs. Asynchronous Decision & Latency Impact**:
  - *Theoretical Synchronous Replication*: Requiring two-phase synchronization across Mumbai and Hyderabad adds:
    $$	ext{Commit Latency}_{	ext{sync}} = 	ext{Local Write (8ms)} + 	ext{Inter-Region RTT (20ms)} + 	ext{Remote Write (8ms)} = \mathbf{36	ext{ ms}}$$
    This would increase database commit latency from 8 ms to 36 ms—a **450% latency increase** that would cause connection pool starvation under 1,200 TPS festival peaks.
  - *Engineered Asynchronous Choice*: Storage replication operates asynchronously with dedicated NVMe storage hardware. The writer instance acknowledges commits locally in 8 ms, while storage blocks stream to Hyderabad with a measured P95 replication lag of **320 ms** and P99 lag of **680 ms**.
  - *RPO Guarantee*: If Mumbai suffers a sudden catastrophic failure, maximum uncommitted data loss is bounded by the storage replication lag ($< 1.0	ext{ second}$), comfortably meeting the RBI Tier-1 mandate of $	ext{RPO} < 60	ext{ seconds}$.
- **Monitoring & Alert Thresholds**:
  - Metric: `AWS/RDS -> AuroraGlobalDBReplicationLag`
  - Alert P1 (Critical): `> 500 ms` for 2 consecutive 60-second periods.
  - Alert P2 (High): `> 1,000 ms` for 1 evaluation period.
  - Automated Action: If lag exceeds 2,000 ms, automated failover promotion is inhibited to prevent data loss; on-call SRE is immediately paged.

---

### 2.2 Amazon DynamoDB (Global Idempotency & Session Management)
- **Mechanism Selection**: **DynamoDB Global Tables** (Version 2019.11.21).
- **Architecture**:
  - Primary Key: `PK = IDEMPOTENCY#<merchant_id>#<order_id>`
  - Provisioned Capacity: 10,000 RCU / 5,000 WCU in Mumbai, replicated to 10,000 RCU / 5,000 WCU in Hyderabad using Replicated Write Capacity Units (rWCUs).
- **Conflict Resolution Strategy**:
  - DynamoDB Global Tables utilizes a **Last-Writer-Wins (LWW)** conflict resolution algorithm based on AWS Nitro internal monotonic time.
  - *Design Mitigation for LWW Clock Skew*: In financial systems, pure LWW can cause race conditions if two updates occur within 10 ms across regions. PaySecure enforces **Conditional Put Expressions** (`attribute_not_exists(PK)`) with lease tokens (`lease_owner`, `lease_expiry`). Once a region establishes an idempotency lease, subsequent writes from the alternate region fail atomically until the lease expires or is released.
- **Monitoring & Alert Thresholds**:
  - Metric: `AWS/DynamoDB -> ReplicationLatency`
  - Alert P1 (Critical): `> 1,000 ms` for 3 consecutive checks.
  - Alert P2 (High): `> 2,500 ms` for 2 consecutive checks.

---

### 2.3 Amazon ElastiCache for Redis (Rate Limiting & Dynamic Configurations)
- **Mechanism Selection**: **ElastiCache Redis Global Datastore**.
- **Topology**:
  - Primary replication group in Mumbai: 3 shards, 6 nodes (`cache.r6g.xlarge`), Redis 7.1 with Cluster Mode Enabled.
  - Secondary replication group in Hyderabad: 3 shards, 6 nodes in read-only mode.
- **Use Cases & Data Classification**:
  - Merchant API rate limit sliding window counters (`INCRBY` / `EXPIRE`).
  - Active merchant routing profiles, fee tiers, and risk scores.
  - Temporary session tokens and UI authorization caches.
- **Failover Promotion**:
  - Secondary cluster in Hyderabad is upgraded from read-only to primary read/write via `aws elasticache failover-global-replication-group` in **under 30 seconds**.
  - Cache warming is unnecessary because all active keys are pre-replicated across regions in real time.
- **Monitoring & Alert Thresholds**:
  - Metric: `AWS/ElastiCache -> GlobalDatastoreReplicationLag`
  - Alert P2 (High): `> 2,000 ms` for 3 consecutive 60-second evaluations.

---

### 2.4 Amazon MSK (Managed Apache Kafka Event Streaming)
- **Mechanism Selection**: **AWS MSK Replicator** (Managed MirrorMaker 2 engine).
- **Replication Scope**:
  - Topics replicated: `payment-events`, `settlement-triggers`, `webhook-deliveries`, `audit-log-events`.
  - Replicator provisions managed container instances across private VPC subnets in Mumbai and Hyderabad, establishing TLS 1.3 mTLS connections.
- **Message Ordering & Consumer Offset Synchronization**:
  - Kafka guarantees message ordering **only within a single partition**.
  - Partition Key Mapping: All payment events use `merchant_id` as the Kafka message key, guaranteeing that all transactions for a given merchant map deterministically to the same partition.
  - MSK Replicator periodically commits consumer group offsets to the secondary cluster (`__consumer_offsets` topic) with an offset synchronization interval of **1,000 ms**.
  - *Failover Consumer Offset Translation*: When consumer services (`settlement-engine`, `webhook-dispatcher`) are spun up in Hyderabad, they query the translated consumer offset checkpoint. To eliminate duplicate webhook dispatches, downstream workers check the transaction status in DynamoDB prior to firing external HTTP POST requests.
- **Monitoring & Alert Thresholds**:
  - Metric: `AWS/Kafka -> ReplicatorLag` & `ConsumerGroupLag`
  - Alert P2 (High): `ReplicatorLag > 10,000 messages` for 5 consecutive minutes.

---

### 2.5 Amazon S3 (Immutable Compliance Archives & Clearing Files)
- **Mechanism Selection**: **S3 Cross-Region Replication (CRR)** with **S3 Replication Time Control (S3 RTC)**.
- **Compliance & Security Controls**:
  - Buckets: `paysecure-compliance-mumbai` -> `paysecure-compliance-hyd`.
  - Both buckets enforce **AWS S3 Object Lock** in **Compliance Mode** (retention period: 7 years as required by RBI and IT Act 2000).
  - Versioning is permanently enabled; deletion markers are replicated to prevent orphaned files.
  - **S3 RTC SLA**: Guarantees that **99.99% of new compliance objects are replicated within 15 minutes**, backed by an AWS service level agreement.
  - All replicated objects are re-encrypted at destination using Hyderabad's KMS multi-region key (`mrk-cde-hyd-replica`).

---

## 3. CAP & PACELC Theoretical Analysis

The fundamental constraints of distributed systems engineering dictate that no payment architecture can evade the trade-offs of the **CAP Theorem** (Consistency, Availability, Partition Tolerance) and the **PACELC Theorem** (Partition: Availability vs. Consistency; Else: Latency vs. Consistency).

```
+---------------------------------------------------------------------------------------------------+
| CAP / PACELC Architectural Classification for PaySecure Stateful Tiers                           |
+--------------------------+---------------------+-------------------+------------------------------+
| Component                | CAP Classification  | PACELC Model      | Financial Justification      |
+--------------------------+---------------------+-------------------+------------------------------+
| Aurora PostgreSQL        | CP                  | PC / EC           | Ledger balance updates must  |
| (Settlement / Balances)  | (Consistent / Part.)| (Consistent always| never double-credit money;   |
|                          |                     | at cost of Latency| latency trade-off accepted.  |
+--------------------------+---------------------+-------------------+------------------------------+
| DynamoDB Global Tables   | AP                  | PA / EL           | Payment idempotency must be  |
| (Idempotency / Sessions) | (Available / Part.) | (Available & Low  | available during network     |
|                          |                     | Latency normal)   | blips; conditional leases CP.|
+--------------------------+---------------------+-------------------+------------------------------+
| ElastiCache Redis        | AP                  | PA / EL           | Rate limits can tolerate brief|
| (Counters / Caches)      | (Available / Part.) | (Low Latency)     | skew without balance risk.   |
+--------------------------+---------------------+-------------------+------------------------------+
| MSK Kafka (Replicator)   | AP                  | PA / EL           | Eventual consistency with    |
| (Asynchronous Events)    | (Available / Part.) | (Eventual Delivery| application-level dedupe.    |
+--------------------------+---------------------+-------------------+------------------------------+
```

---

## 4. Split-Brain Prevention & Data Reconciliation Post-Failback

### 4.1 Fencing the Former Primary (Eliminating Split-Brain)
If a degraded Mumbai region partially recovers while Hyderabad is operating as the promoted primary, two writers could simultaneously accept transactions. PaySecure eliminates split-brain via **Three-Stage Fencing**:
1. **Network Fencing**: The failover automation script revokes security group ingress rules on the Mumbai Aurora database cluster (`aurora-sg-mumbai`), severing TCP 5432 connections from all application nodes.
2. **Read-Only Parameter Group Enforcement**: The failover script applies an emergency parameter group to Mumbai Aurora setting `default_transaction_read_only = on`.
3. **Route 53 DNS Fencing**: The primary Route 53 health check status is inverted to forced `UNHEALTHY`, ensuring zero traffic reaches Mumbai ALBs.

### 4.2 Data Reconciliation Protocol
During the 75-second Aurora failover promotion window, any transactions that were committed in Mumbai but not yet replicated to Hyderabad prior to detachment represent the **Failover Replication Gap** ($\Delta_{	ext{rep}} pprox 300 - 650	ext{ ms}$, representing $\sim 10 - 25	ext{ transactions}$).

Post-incident reconciliation executes via `scripts/failover/reconcile-split-brain.py`:
1. **WAL Diff Extraction**: Extract write-ahead log entries from Mumbai Aurora for the 5-minute window surrounding the failover event.
2. **Transaction Cross-Matching**: Compare transaction IDs in the Mumbai WAL diff against the newly created transactions in Hyderabad Aurora.
3. **Banking Settlement Verification**: For any transaction found in Mumbai WAL but absent in Hyderabad, invoke the NPCI / Acquiring Bank UPI Verification API to confirm whether funds were debited from the customer.
4. **Ledger Adjustment**: If the bank debited funds, inject a compensatory credit record into Hyderabad Aurora with transaction note `POST_DR_RECONCILIATION_CREDIT`. If the bank has no record, mark the transaction as `FAILED_EXPIRED` and notify the merchant via webhook.
