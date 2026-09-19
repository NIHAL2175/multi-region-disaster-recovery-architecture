# PaySecure Gateway: Data Replication & Failover Sequence Diagrams

**Document ID**: PSG-DATA-002-SEQ  
**Syntax**: Mermaid Sequence Diagrams (Standard GitHub Markdown Compatible)  
**Classification**: Strictly Confidential - Distributed Systems Engineering  

---

## 1. Sequence Diagram 1: Normal Write-Path (Primary Region: Mumbai)

In standard production operations, 100% of transaction writes are processed by **AWS Mumbai (`ap-south-1`)**. The writer instance commits transactions locally to 6-way Multi-AZ storage, while storage blocks stream asynchronously to the Hyderabad reader replica over the AWS dedicated backbone.

```mermaid
sequenceDiagram
    autonumber
    actor Merchant as Merchant / Consumer App
    participant Route53 as AWS Route 53 (DNS)
    participant ALB as Mumbai ALB + WAF
    participant API as payment-api (Mumbai)
    participant Dynamo as DynamoDB Global Table (MUM)
    participant TxnProc as transaction-processor (MUM)
    participant CDE as tokenisation-service (CDE)
    participant Bank as NPCI / Card Network
    participant AuroraMum as Aurora PG Writer (MUM)
    participant AuroraHyd as Aurora PG Reader (HYD)
    participant MSK as Amazon MSK Kafka (MUM)

    Merchant->>Route53: DNS Query api.paysecure.in
    Route53-->>Merchant: Returns Mumbai ALB IP (TTL: 30s)
    Merchant->>ALB: POST /api/v1/payments (Idempotency-Key)
    ALB->>API: Route HTTP Request
    API->>Dynamo: PutItem (PK=Idempotency-Key, status=INITIATED)
    Dynamo-->>API: 200 OK (Lease Acquired in 8ms)
    
    API->>TxnProc: gRPC authorizePayment()
    TxnProc->>CDE: mTLS tokenizeCard() [Port 8443]
    CDE-->>TxnProc: Returns Encrypted Token (KMS mrk-mumbai)
    
    TxnProc->>Bank: Dispatch UPI / Card Auth Request
    Bank-->>TxnProc: Auth Approved (Bank Reference Number)
    
    TxnProc->>AuroraMum: BEGIN; INSERT INTO transactions; COMMIT;
    AuroraMum-->>TxnProc: Transaction Committed (10ms)
    
    par Async Storage Replication
        AuroraMum-)AuroraHyd: Storage-level WAL streaming (< 650ms lag)
    and Async Event Streaming
        TxnProc-)MSK: Publish Event (payment-events)
    and DynamoDB Cross-Region Sync
        Dynamo-)Dynamo: Bi-directional replication to HYD (< 800ms)
    end
    
    TxnProc-->>API: Payment Success Payload
    API-->>Merchant: HTTP 200 OK {status: "SUCCESS", txn_id: "TXN-998822"}
```

---

## 2. Sequence Diagram 2: Normal Read-Path (Cross-Region Read Scalability)

To minimize latency for merchant reporting and dashboard queries, read requests are served locally from reader replicas in the respective region, while writes flow exclusively to the primary writer.

```mermaid
sequenceDiagram
    autonumber
    actor Merchant as Merchant Analytics Dashboard
    participant Route53 as Route 53 Geolocation DNS
    participant ALBHyd as Hyderabad ALB
    participant Portal as merchant-portal Pods (HYD)
    participant RedisHyd as ElastiCache Redis Replica (HYD)
    participant AuroraHyd as Aurora Reader Replica (HYD)
    participant S3Hyd as Amazon S3 Compliance (HYD)

    Merchant->>Route53: Query portal.paysecure.in (from Bangalore)
    Route53-->>Merchant: Returns Hyderabad ALB IP (Lowest Latency: 9ms)
    Merchant->>ALBHyd: GET /portal/v1/settlements/summary
    ALBHyd->>Portal: Forward Request
    
    Portal->>RedisHyd: GET merchant_config:M-4412
    alt Cache Hit (98% Probability)
        RedisHyd-->>Portal: Return Cached Merchant Metadata (1ms)
    else Cache Miss
        Portal->>AuroraHyd: SELECT * FROM merchant_configs WHERE id = 'M-4412'
        AuroraHyd-->>Portal: Return Row from Local Read Replica (3ms)
    end
    
    Portal->>AuroraHyd: SELECT SUM(net_amount), status FROM settlement_batches WHERE merchant_id = 'M-4412'
    AuroraHyd-->>Portal: Returns Historical Aggregates (Local Replica Read)
    
    Portal-->>Merchant: HTTP 200 OK with Real-time Settlement Summary
```

---

## 3. Sequence Diagram 3: Failover Write-Path (Secondary Promoted: Hyderabad)

When Mumbai suffers a regional outage, Route 53 health checks detect failure within 30 seconds. The automated orchestrator detaches the Hyderabad Aurora cluster, scales EKS compute, and promotes Hyderabad to primary writer.

```mermaid
sequenceDiagram
    autonumber
    actor Merchant as Merchant / Consumer App
    participant Route53 as AWS Route 53
    participant Orchestrator as Failover Orchestrator (Lambda/EC2)
    participant ALBHyd as Hyderabad ALB + WAF
    participant EKS as paysecure-hyd EKS Cluster
    participant AuroraHyd as Aurora PostgreSQL (HYD)
    participant DynamoHyd as DynamoDB Global Table (HYD)
    participant Bank as NPCI / Partner Bank

    Note over Route53,Orchestrator: Mumbai Region Fails at T=00:00
    Route53->>Orchestrator: Health Check Failed (3 consecutive fails at 10s)
    Orchestrator->>AuroraHyd: aws rds remove-from-global-cluster (Detach & Promote)
    Note over AuroraHyd: Storage Catchup & Promotion (~75 Seconds)
    AuroraHyd-->>Orchestrator: Cluster Promoted to Read/Write Master
    
    Orchestrator->>EKS: Scale deployment payment-api (12 -> 36 Pods)
    Orchestrator->>Route53: Invert Health Status (Route All Ingress to Hyderabad)
    
    Note over Merchant,ALBHyd: Traffic Shifts to Hyderabad at T=03:30
    Merchant->>Route53: Query api.paysecure.in
    Route53-->>Merchant: Returns Hyderabad ALB IP
    Merchant->>ALBHyd: POST /api/v1/payments (Idempotency-Key)
    ALBHyd->>EKS: Route to Local payment-api Pod
    
    EKS->>DynamoHyd: PutItem (PK=Idempotency-Key, status=PROCESSING)
    DynamoHyd-->>EKS: 200 OK (Local Lease Acquired)
    
    EKS->>Bank: Dispatch UPI Payment Auth
    Bank-->>EKS: Auth Approved
    
    EKS->>AuroraHyd: INSERT INTO transactions (status='SUCCESS');
    AuroraHyd-->>EKS: Committed Locally in Hyderabad (8ms)
    EKS-->>Merchant: HTTP 200 OK {status: "SUCCESS", region: "ap-south-2"}
```

---

## 4. Sequence Diagram 4: Failover Read-Path (Secondary Serving 100% Ingress)

During full disaster recovery operation in Hyderabad, all reporting, merchant portals, reconciliation jobs, and customer transaction queries are served autonomously from `ap-south-2`.

```mermaid
sequenceDiagram
    autonumber
    actor Merchant as Merchant Operations
    participant ALBHyd as Hyderabad ALB
    participant Portal as merchant-portal (HYD)
    participant RedisHyd as ElastiCache (Promoted Master in HYD)
    participant AuroraHyd as Aurora PostgreSQL (Promoted Master in HYD)
    participant S3Hyd as S3 Bucket (HYD Replica)

    Merchant->>ALBHyd: GET /portal/v1/transactions?date=2026-09-12
    ALBHyd->>Portal: Forward Request
    Portal->>RedisHyd: GET session_token:AUTH-9912
    RedisHyd-->>Portal: Valid Session (Promoted Redis Master)
    
    Portal->>AuroraHyd: SELECT * FROM transactions WHERE date = '2026-09-12' ORDER BY created_at DESC LIMIT 50;
    AuroraHyd-->>Portal: Returns Result Set from Local Promoted Cluster
    
    Portal->>S3Hyd: GET /reports/2026-09-12/settlement-recon.pdf
    S3Hyd-->>Portal: Download PDF (Pre-replicated via S3 RTC)
    Portal-->>Merchant: HTTP 200 OK with Transaction History & Invoice
```

---

## 5. Sequence Diagram 5: Data Reconciliation Post-Failback

Once Mumbai is fully recovered and certified stable, the automated reconciliation engine verifies data consistency between Mumbai's legacy storage logs and Hyderabad's promoted ledger before executing controlled failback.

```mermaid
sequenceDiagram
    autonumber
    participant SRE as Lead DBA / SRE Commander
    participant ReconScript as reconcile-split-brain.py
    participant AuroraHyd as Active Aurora Writer (HYD)
    participant AuroraMum as Restored Aurora (MUM - Read Only)
    participant Dynamo as DynamoDB Global Table
    participant Bank as NPCI / Bank Settlement Verification API
    participant MSK as Amazon MSK Replicator

    SRE->>ReconScript: Execute Controlled Reconciliation Audit
    ReconScript->>AuroraMum: Extract WAL Records for Failover Window (T_failover - 5m)
    AuroraMum-->>ReconScript: 22,410 Transaction IDs Extracted
    
    ReconScript->>AuroraHyd: Query Matching Transaction IDs
    AuroraHyd-->>ReconScript: 22,398 Matched | 12 Unmatched (Replication Gap)
    
    loop For Each of the 12 Unmatched Transactions
        ReconScript->>Bank: Query UPI Order Status (Bank Reference / UTR)
        alt Bank Confirms Debit Success
            Bank-->>ReconScript: Status: DEBIT_CONFIRMED
            ReconScript->>AuroraHyd: INSERT INTO transactions (id, status='POST_DR_RECON_CREDIT')
            AuroraHyd-->>ReconScript: Compensatory Ledger Credit Created
        else Bank Confirms No Debit
            Bank-->>ReconScript: Status: NOT_FOUND / EXPIRED
            ReconScript->>AuroraHyd: INSERT INTO transactions (id, status='FAILED_ABANDONED')
            AuroraHyd-->>ReconScript: Marked as Expired Failure
        end
    end
    
    ReconScript-->>SRE: Reconciliation Complete: 100% Transactions Accounted For
    SRE->>AuroraMum: Establish Reverse Global Replication (Attach Mumbai as Reader)
    AuroraHyd-)AuroraMum: Sync Hyderabad Writes back to Mumbai
    SRE->>SRE: Ready for Zero-Data-Loss Managed Failback
```
