# PaySecure Gateway: Active-Active Multi-Region Architecture Design

**Document ID**: PSG-ARCH-002-AA  
**Topology**: Bi-Directional Multi-Region Active-Active  
**Active Regions**: AWS `ap-south-1` (Mumbai) & AWS `ap-south-2` (Hyderabad)  
**Target RTO**: Near-Zero (< 30 Seconds for DNS Shift / 0 Seconds for Dual-Ingress)  
**Target RPO**: < 1 Minute (Near-Zero for Partitioned Keys / Storage Lag Bound)  
**Classification**: Strictly Confidential - Payment Distributed Systems Architecture  

---

## 1. Executive Summary & Architectural Paradigm

In an **Active-Active Multi-Region Architecture**, both AWS Mumbai (`ap-south-1`) and AWS Hyderabad (`ap-south-2`) simultaneously accept and process live merchant transactions. Incoming client requests from PaySecure's 45,000 merchants and millions of consumers are routed to the nearest or least-loaded region via AWS Route 53 Latency-Based Routing (LBR) or Geolocation Routing policies.

While Active-Active eliminates the concept of "failover downtime"—since a catastrophic loss of one region simply results in DNS shedding traffic to the surviving active region—it introduces extraordinary distributed systems complexity:
1. **The Distributed Settlement Challenge**: How do two regions concurrently process debit/credit ledger writes against the same merchant nodal account without causing double-spending, negative balances, or race conditions?
2. **Transaction Ordering & Idempotency**: How is global ordering maintained when cross-region network latency (15–25 ms) exceeds the execution time of individual microservice operations?
3. **Database Concurrency & Write Partitioning**: Because standard relational databases cannot support multi-master writes across 700 km without severe locking overhead, data partitioning by merchant ID or payment method is mathematically imperative.

This document details the complete design, conflict resolution algorithms, idempotency synchronization, and distributed ledger reconciliation required to operate PaySecure Gateway in an Active-Active configuration.

---

## 2. Ingress Traffic Routing & Global DNS Steering

```
                             [ Merchant APIs & Consumers ]
                                           │
                                           ▼
                       [ AWS Route 53 Latency-Based Routing (LBR) ]
                         - Record: api.paysecure.in
                         - Policy: Latency / Health-Checked Dual Anycast
                                           │
                    ┌──────────────────────┴──────────────────────┐
                    │ (RTT: 8ms from North/West)                  │ (RTT: 9ms from South/East)
                    ▼                                             ▼
     [ Mumbai Ingress: ap-south-1 ]                [ Hyderabad Ingress: ap-south-2 ]
     [ ALB + WAFv2 (50% Traffic)  ]                [ ALB + WAFv2 (50% Traffic)     ]
                    │                                             │
                    ▼                                             ▼
     [ EKS: paysecure-mumbai ]                     [ EKS: paysecure-hyd ]
     (24 Nodes / 180 Pods)                         (24 Nodes / 180 Pods)
```

### 2.1 Latency-Based Routing with Fast Health Checks
- **AWS Route 53 Latency Resource Record Sets**: Traffic is routed based on AWS's global network latency measurements between client resolvers and the AWS edge. Merchants operating in Western/Northern India naturally resolve to Mumbai (`ap-south-1`), while merchants in Southern/Eastern India resolve to Hyderabad (`ap-south-2`).
- **Health Check Fast Thresholds**: Each regional Application Load Balancer endpoint is probed by Route 53 health checkers at **10-second fast intervals** with a failure threshold of 2. If Mumbai degrades, Route 53 automatically stops serving Mumbai's IP within 20 seconds, steering 100% of incoming requests to Hyderabad.
- **Anycast BGP Edge Routing via AWS Global Accelerator**: For high-volume enterprise merchants (processing >100 TPS), PaySecure provisions AWS Global Accelerator. Static Anycast IP addresses terminate TCP connections at the nearest AWS edge point of presence (PoP), routing traffic over AWS private fiber directly to the healthy region, bypassing public DNS TTL caching delays entirely.

---

## 3. Data Partitioning, Idempotency & Database Concurrency

The fundamental law of distributed data systems—formalized by Eric Brewer's **CAP Theorem**—dictates that a distributed system cannot simultaneously achieve Consistency, Availability, and Partition Tolerance. Under network partitions between Mumbai and Hyderabad, PaySecure must prioritize **Consistency (C)** for financial funds transfer while maintaining **Availability (A)** through intelligent domain partitioning.

```
+---------------------------------------------------------------------------------------------------+
| Multi-Region Stateful Data Partitioning Architecture                                              |
+-------------------------+-------------------------+----------------------+------------------------+
| Component               | Replication Engine      | Consistency Model    | Conflict Resolution    |
+-------------------------+-------------------------+----------------------+------------------------+
| Idempotency & Sessions  | DynamoDB Global Tables  | Eventual Consistency | Last-Writer-Wins (LWW) |
|                         | (Multi-Active Dual-Write| (Local Read: Strong) | with Monotonic Clock   |
+-------------------------+-------------------------+----------------------+------------------------+
| Transaction Ledger      | Aurora Global Database  | Read-Local / Single- | Home-Region Affinity   |
| (Aurora PostgreSQL)     | with Write Forwarding   | Writer Strong Cons.  | (Partitioned Writes)   |
+-------------------------+-------------------------+----------------------+------------------------+
| Merchant Configuration  | ElastiCache Redis       | Eventual Consistency | Primary Master in MUM, |
| & Rate Limits           | Global Datastore        | (Read-Only Secondary)| Async Replicated to HYD|
+-------------------------+-------------------------+----------------------+------------------------+
| Event Streams           | Amazon MSK with         | At-Least-Once Delivery| Deduplication via      |
| (Kafka Topics)          | MSK Replicator          | (Eventual Ordering)  | Transaction UUID Cache |
+-------------------------+-------------------------+----------------------+------------------------+
```

### 3.1 Idempotency Key Coordination via DynamoDB Global Tables
To prevent double-charging when both regions are active, the idempotency coordination layer is built entirely on Amazon DynamoDB Global Tables:
1. **Deterministic Partition Key**:
   - Primary Key: `PK = IDEMPOTENCY#<merchant_id>#<order_id>`
   - Attributes: `amount`, `currency`, `region_id`, `status` (`INITIATED`, `PROCESSING`, `COMMITTED`, `REJECTED`), `lease_expiry`, `response_payload`.
2. **Atomic Conditional Leases**:
   When `payment-api` receives a transaction in either region, it performs an atomic conditional write:
   ```python
   dynamodb.put_item(
       TableName='paysecure-idempotency-sessions',
       Item={
           'PK': {'S': f'IDEMPOTENCY#{merchant_id}#{order_id}'},
           'status': {'S': 'PROCESSING'},
           'origin_region': {'S': current_region},
           'timestamp_epoch_ms': {'N': str(current_epoch_ms)},
           'ttl': {'N': str(int(time.time() + 86400))}
       },
       ConditionExpression='attribute_not_exists(PK) OR (status = :failed)'
   )
   ```
   If a client retries the same request against the alternate region 200 ms later, the conditional write fails with `ConditionalCheckFailedException`, returning the in-flight status or committed receipt.

### 3.2 Relational Transaction Ledger: Aurora with Home-Region Partitioning
PostgreSQL requires strict ACID guarantees. Multi-master synchronous write replication across 700 km introduces a 20 ms round-trip penalty per database commit, collapsing P99 transaction latency from 180 ms to over 350 ms (violating NPCI's 300 ms SLA).

PaySecure solves this via **Merchant Home-Region Affinity (Tenant Partitioning)**:
- **Merchant Sharding**: 45,000 merchants are partitioned based on their registration home region:
  - **Partition A (Merchants 1 to 22,500)**: Home Region = Mumbai (`ap-south-1`).
  - **Partition B (Merchants 22,501 to 45,000)**: Home Region = Hyderabad (`ap-south-2`).
- **Aurora Global Database Write Forwarding**:
  - In Mumbai, Aurora Cluster A acts as primary writer for Partition A.
  - In Hyderabad, Aurora Cluster B acts as primary writer for Partition B.
  - If a transaction for Merchant 23,000 arrives at Mumbai ALB via DNS, the `transaction-processor` routes the write query over the Inter-Region Transit Gateway to Hyderabad Cluster B. This cross-region query occurs in ~18 ms, comfortably fitting inside the 180 ms P99 transaction budget!

---

## 4. Cross-Region Kafka Event Streaming & Deduplication

```
  [ Mumbai EKS Pods ]                                             [ Hyderabad EKS Pods ]
           │                                                                 │
           ▼                                                                 ▼
[ MSK Mumbai: 6 Brokers ]                                       [ MSK Hyderabad: 6 Brokers ]
Topic: payment-events                                           Topic: payment-events
           │                                                                 │
           │                     AWS MSK Replicator                          │
           └──────────────────► (Bi-Directional Sync)  ◄─────────────────────┘
                                Topic: payment-events-mum
                                Topic: payment-events-hyd
                                             │
                                             ▼
                             [ Distributed Settlement Engine ]
                             - Transaction UUID Deduplication Cache
                             - In-Memory Sliding Window (5 Minutes)
                             - Reconciliation Ledger DB
```

### 4.1 Topic Mirroring & Offset Handling
- Cross-region Kafka streaming utilizes **AWS MSK Replicator**.
- Topics originating in Mumbai are replicated to Hyderabad under the namespace `mum.payment-events`, while Hyderabad topics mirror to Mumbai as `hyd.payment-events`.
- Consumer groups consume from both local and mirrored topics, executing stream union.
- **Deduplication Engine**:
  Because Kafka provides *at-least-once* delivery semantics across cross-region replicators, network hiccups can cause duplicate event publishing. The `settlement-engine` utilizes an in-memory Redis cluster sliding window holding `transaction_id` hashes for 30 minutes. Any duplicate event arriving across regions is discarded before executing ledger accounting writes.

---

## 5. Split-Brain Prevention & Network Partition Fencing

A catastrophic scenario in active-active architectures is a **network partition** where the inter-region backbone between Mumbai and Hyderabad fails, but both regions remain connected to the internet and continue accepting payments from clients.

Without strict fencing, merchants could process conflicting balance debits in both regions, resulting in severe financial loss. PaySecure implements **Quorum-Based Fencing via DynamoDB & Route 53**:

```
                                  [ Global Heartbeat Witness ]
                             Amazon DynamoDB Global Heartbeat Table
                                             │
                       ┌─────────────────────┴─────────────────────┐
                       ▼                                           ▼
             [ Mumbai Heartbeat ]                        [ Hyderabad Heartbeat ]
             Lease Period: 5s                            Lease Period: 5s
             Ping Status: Active                         Ping Status: Active
```

1. **Heartbeat Witness Protocol**:
   - An independent witness table in DynamoDB maintains a monotonic epoch counter.
   - Every 3 seconds, the `health-monitor` microservice in each region attempts to renew its regional lease (`PUT heartbeat WITH version = version + 1`).
2. **Automatic Region Fencing (Degraded Mode)**:
   - If inter-region replication latency exceeds **5,000 ms** for 3 consecutive checks (indicating a network split), the region that loses quorum lease renewal (designated as Hyderabad by default priority rules) executes **Automated Self-Fencing**:
     - Hyderabad stops accepting new transaction writes for Partition A.
     - Ingress ALB returns HTTP 503 with header `Retry-After: 5` and steers DNS via Route 53 exclusively to Mumbai.
     - Transactions for Partition B continue locally in read-only / authorization-only mode.
3. **Data Reconciliation Post-Partition**:
   - Once network connectivity is restored, the automated reconciliation engine compares transaction journals from both clusters, identifying out-of-order writes and applying standard double-entry bookkeeping ledger adjustments.

---

## 6. End-to-End Latency Budget Decomposition

Under NPCI UPI Technical Specifications, total end-to-end processing latency from customer mobile application to gateway response must remain **strictly below 300 ms**.

```
+---------------------------------------------------------------------------------------------------+
| Active-Active P99 Latency Budget Breakdown (Target: < 300 ms)                                     |
+------------------------------------+--------------------------+-----------------------------------+
| Transaction Processing Phase       | Single-Region (Mumbai)   | Active-Active (Cross-Region)      |
+------------------------------------+--------------------------+-----------------------------------+
| 1. DNS & Network Ingress (TLS 1.3) | 35 ms                    | 38 ms (Route 53 LBR / Edge)       |
| 2. WAF & API Gateway Validation    | 12 ms                    | 12 ms                             |
| 3. DynamoDB Idempotency Write      | 8 ms (Local Write)       | 9 ms (Global Table Local Commit)  |
| 4. Fraud Detection & Rate Limiting | 20 ms (gRPC + Redis)     | 20 ms                             |
| 5. Tokenisation Service (mTLS CDE) | 15 ms                    | 15 ms                             |
| 6. Acquiring Bank / NPCI Round-Trip| 70 ms                    | 70 ms                             |
| 7. Aurora PostgreSQL DB Commit     | 12 ms (Local Storage)    | 32 ms (Home-Region Forwarding)    |
| 8. MSK Kafka Event Ingestion       | 8 ms                     | 9 ms                              |
+------------------------------------+--------------------------+-----------------------------------+
| TOTAL END-TO-END P99 LATENCY       | 180 ms                   | 205 ms [COMFORTABLY < 300 ms SLA] |
+------------------------------------+--------------------------+-----------------------------------+
```
Even when a transaction requires cross-region write forwarding over the AWS backbone (adding ~20 ms), total P99 transaction latency is **205 ms**, leaving an ample **95 ms buffer** before violating NPCI regulatory limits!

---

## 7. Operational Complexity & Maintenance Overhead

While Active-Active achieves instantaneous recovery from regional failures, the operational burden on the platform engineering team is immense:
- **Dual Active Capacity Management**: Both regions must be provisioned with sufficient capacity (at least 70% each) to absorb 100% of national load in the event of an abrupt regional drop, requiring higher baseline server counts.
- **Continuous Conflict Monitoring**: Platform engineers must continuously monitor cross-region replication lag, Kafka consumer group offsets, and DynamoDB conflict resolution counters.
- **CI/CD Canary Complexity**: Deploying application changes across two simultaneously active regions requires strict canary release strategies with backward-compatible database schema migrations (Expand-Contract pattern).


---

## 8. Microsecond Clock Synchronization & Amazon Time Sync Service

In an Active-Active payment gateway deployment processing 1,200 TPS across regions separated by 700 km, physical clock drift between EKS worker nodes presents an immediate threat to transaction ordering and Last-Writer-Wins (LWW) conflict resolution in DynamoDB Global Tables.

### 8.1 Physical Clock Skew Vulnerability
If an EC2 instance in Mumbai has a local clock that is +45 ms ahead of an instance in Hyderabad, a payment status update executed in Hyderabad at $T=100	ext{ ms}$ with a local timestamp of $100	ext{ ms}$ would be overwritten or superseded by a stale update executed in Mumbai at $T=80	ext{ ms}$ with an inflated local timestamp of $125	ext{ ms}$. In financial settlement ledgers, this causes the "Lost Update Problem", silently discarding refund operations or ledger adjustments.

### 8.2 Amazon Time Sync Service (Chrony PTP Configuration)
To eliminate clock skew vulnerabilities, all EKS worker nodes across both Mumbai and Hyderabad synchronize against the **Amazon Time Sync Service** using the Precision Time Protocol (PTP) hardware clocks embedded within AWS Nitro instances:
- **Reference Clock IP**: `169.254.169.123` (Link-local redundant atomic clock network).
- **Daemon Configuration**: `chrony` configured with aggressive polling and drift correction:
  ```ini
  # /etc/chrony.conf on EKS Worker Nodes
  server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4
  makestep 0.1 3
  maxupdateskew 100.0
  dumponexit
  dumpdir /var/lib/chrony
  rtcsync
  logchange 0.5
  ```
- **Guaranteed Clock Bound**: Amazon Time Sync guarantees node clock drift strictly within **$\pm 1	ext{ millisecond}$** of UTC across all AWS regions.
- **Microsecond Timestamp Enforcement**: All application entities append an RFC 3339 monotonic timestamp combined with an incremental counter: `timestamp_iso = 2026-09-12T12:00:00.123456Z#001`. This guarantees deterministic, reproducible transaction ordering across distributed Kafka consumers.

---

## 9. Distributed Saga Orchestration vs. Two-Phase Commit (2PC)

A frequent BCRB question asks: *Why not use Distributed Two-Phase Commit (2PC) or XA transactions across Mumbai and Hyderabad to guarantee strict ACID transactions for every single write?*

### 9.1 Mathematical Impossibility of Synchronous 2PC at 1,200 TPS
Consider a synchronous Two-Phase Commit protocol coordinating across Mumbai and Hyderabad:
1. **Prepare Phase**: Application sends `PREPARE` to Mumbai Aurora and Hyderabad Aurora over AWS Transit Gateway ($	ext{RTT} = 20	ext{ ms}$).
2. **Commit Phase**: Upon receiving `VOTE_COMMIT` from both databases, application sends `COMMIT` ($	ext{RTT} = 20	ext{ ms}$).
3. **Total Protocol Latency**:
   $$	ext{Latency}_{	ext{2PC}} = 	ext{Prepare (20ms)} + 	ext{Commit (20ms)} + 	ext{DB Write IOPS (15ms)} = \mathbf{55	ext{ ms}}$$
4. **Lock Contention Collapse**: During those 55 ms, database row-level locks on merchant nodal accounts, settlement balance rows, and inventory items must remain open. Under Little's Law ($L = \lambda W$), at 1,200 TPS, an average of $1,200 	imes 0.055 = 66	ext{ concurrent distributed locks}$ remain held at any millisecond. During flash sales, row contention causes catastrophic lock wait timeouts, cascading deadlocks, and connection pool exhaustion.

### 9.2 The Choreographed Saga Pattern with Compensating Transactions
PaySecure explicitly rejects synchronous 2PC in favor of an asynchronous **Choreographed Saga Pattern** mediated by Apache Kafka and DynamoDB:

```
[ Merchant Order ] ──► [ payment-api ] ──► (Local Commit: INITIATED)
                              │
                              ▼ (MSK Kafka: order-created)
                     [ transaction-processor ]
                              │
            ┌─────────────────┴─────────────────┐
            ▼ (Authorize with Bank)             ▼ (Authorize Failure)
  (State: AUTHORIZED)                 (State: FAILED_AUTH)
            │                                   │
            ▼ (MSK Kafka: txn-authorized)       ▼ (Trigger Compensation)
   [ settlement-engine ]               [ webhook-dispatcher ]
   (Credit Pending Balance)            (Notify Merchant of Failure)
```

1. **Forward Steps**: Each microservice executes its local database transaction within its home region in under 5 ms and emits a domain event to local Amazon MSK.
2. **Compensating Steps**: If downstream validation fails in the alternate region (e.g., merchant nodal account frozen, daily processing limit breached), the `settlement-engine` publishes a `TransactionCompensateEvent`.
3. **Automated Rollback**: The originating service consumes the compensation event and executes a reverse ledger credit (`TRANSACTION_REVERSED`), guaranteeing eventual consistency without holding distributed distributed database locks.

---

## 10. PACELC Theorem Evaluation for Payment Aggregation

While the classical CAP Theorem evaluates system behavior exclusively during network partitions, the **PACELC Theorem** (Abadi, 2012) provides a more comprehensive framework by stating:
> *If there is a Partition (P), how does the system trade off Availability (A) and Consistency (C); Else (E), when the system is running normally without partitions, how does it trade off Latency (L) and Consistency (C)?*

PaySecure's Active-Active architecture is strictly classified as a **PC/EC** system for transactional financial ledgers, and a **PA/EL** system for stateless session management:

1. **Transactional Ledger Layer (Aurora PostgreSQL)**:
   - **Under Partition (P)**: Chooses **Consistency (C)** over Availability. If inter-region connectivity drops, writes to remote merchant partitions are rejected rather than risking inconsistent account debits.
   - **Else Normal (E)**: Chooses **Consistency (C)** over Latency. Writes are forwarded to the authoritative home region ($+18	ext{ ms}$ overhead) to maintain absolute ACID auditability.
2. **Session & Idempotency Layer (DynamoDB Global Tables)**:
   - **Under Partition (P)**: Chooses **Availability (A)**. Both regions accept read/write requests to ensure customers can retry payment forms without experiencing 500 errors.
   - **Else Normal (E)**: Chooses **Latency (L)**. Reads and writes execute against local region storage within 8 ms, replicating asynchronously in the background.

This dual-tier architectural partitioning demonstrates world-class distributed systems discipline, satisfying both the latency demands of NPCI UPI and the audit rigour of the Reserve Bank of India.
