# PaySecure Gateway: Current-State Single-Region Architecture Documentation

**Document ID**: PSG-ARCH-001  
**System**: PaySecure Core Payment Processing Platform  
**Current Production Deployment**: AWS Region `ap-south-1` (Mumbai, India)  
**Classification**: Strictly Confidential - Regulated Financial Infrastructure  
**Baseline Service Availability**: 99.92% (~7.01 hours annual downtime)  

---

## 1. Architectural Overview & Context

PaySecure Gateway Private Limited operates as an RBI-authorized Payment Aggregator (PA) processing approximately **3.2 million transactions daily** with an aggregate settlement value exceeding **₹500 crore INR (~$60M USD)** across a merchant portfolio of **45,000 active enterprises**. The transaction pattern exhibits high diurnal variance, peaking during national festivals and e-commerce flash sales at **1,200 Transactions Per Second (TPS)** with an average baseline of 250 TPS during standard business hours.

The existing production infrastructure operates exclusively within the **AWS Asia Pacific (Mumbai) region (`ap-south-1`)**. While the system utilizes three Availability Zones (`ap-south-1a`, `ap-south-1b`, and `ap-south-1c`) to survive localized data centre failures, the entire transaction processing capability, data persistence layer, cryptographic key hierarchy, and external bank connectivity terminate within this single AWS region. This single-region concentration represents an existential business risk and directly violates the upcoming **RBI Master Direction on Payment Systems (2024)** mandate requiring automated multi-region disaster recovery with near-zero RPO and RTO under 5 minutes.

---

## 2. Virtual Private Cloud (VPC) & Network Segmentation

The production environment is deployed in a dedicated Virtual Private Cloud (VPC) spanning three Availability Zones with a `/16` CIDR block: `10.100.0.0/16`. The network topology enforces strict defence-in-depth isolation using three tiered subnet layers across all three AZs:

```
+---------------------------------------------------------------------------------------------------+
| PaySecure Production VPC: 10.100.0.0/16 (AWS ap-south-1 Mumbai)                                   |
|                                                                                                   |
|  +---------------------------+  +---------------------------+  +-------------------------------+  |
|  | AZ ap-south-1a            |  | AZ ap-south-1b            |  | AZ ap-south-1c                |  |
|  |                           |  |                           |  |                               |  |
|  | Public Subnet A           |  | Public Subnet B           |  | Public Subnet C               |  |
|  | 10.100.1.0/24             |  | 10.100.2.0/24             |  | 10.100.3.0/24                 |  |
|  | [ALB / WAF / NAT GW A]    |  | [ALB / WAF / NAT GW B]    |  | [ALB / WAF / NAT GW C]        |  |
|  +---------------------------+  +---------------------------+  +-------------------------------+  |
|               |                              |                              |                     |
|  +---------------------------+  +---------------------------+  +-------------------------------+  |
|  | Application Subnet A      |  | Application Subnet B      |  | Application Subnet C          |  |
|  | 10.100.10.0/22            |  | 10.100.14.0/22            |  | 10.100.18.0/22                |  |
|  | [EKS Node Group 1: 8 EC2] |  | [EKS Node Group 2: 8 EC2] |  | [EKS Node Group 3: 8 EC2]     |  |
|  | - payment-api             |  | - transaction-processor   |  | - settlement-engine           |  |
|  | - fraud-detection         |  | - merchant-portal         |  | - notification-service        |  |
|  | - reconciliation-worker   |  | - rate-limiter            |  | - webhook-dispatcher          |  |
|  | - health-monitor          |  | - audit-logger            |  | [CDE: tokenisation-service]   |  |
|  +---------------------------+  +---------------------------+  +-------------------------------+  |
|               |                              |                              |                     |
|  +---------------------------+  +---------------------------+  +-------------------------------+  |
|  | Database / Data Subnet A  |  | Database / Data Subnet B  |  | Database / Data Subnet C      |  |
|  | 10.100.30.0/24            |  | 10.100.31.0/24            |  | 10.100.32.0/24                |  |
|  | [Aurora Primary Writer]   |  | [Aurora Read Replica 1]   |  | [Aurora Read Replica 2]       |  |
|  | [MSK Broker 1 & 2]        |  | [MSK Broker 3 & 4]        |  | [MSK Broker 5 & 6]            |  |
|  | [ElastiCache Shard 1]     |  | [ElastiCache Shard 2]     |  | [ElastiCache Shard 3]         |  |
|  +---------------------------+  +---------------------------+  +-------------------------------+  |
+---------------------------------------------------------------------------------------------------+
```

### 2.1 Subnet Allocation and Routing
1. **Public Ingress Subnets** (`10.100.1.0/24`, `10.100.2.0/24`, `10.100.3.0/24`):
   - Hosts the internet-facing Application Load Balancer (ALB) protected by AWS WAFv2 and AWS Shield Standard.
   - Hosts one NAT Gateway per AZ to ensure multi-AZ outbound egress redundancy.
   - Associated with an Internet Gateway (IGW) route table (`0.0.0.0/0 -> igw-xxxx`).
2. **Private Application Subnets** (`10.100.10.0/22`, `10.100.14.0/22`, `10.100.18.0/22`):
   - Hosts the Amazon EKS managed worker nodes (24 x `m6i.2xlarge`).
   - Default route targets the respective AZ's NAT Gateway for external API calls (e.g., bank payment APIs, SMS gateways).
   - Direct inbound internet access is completely blocked.
3. **Isolated Private Data Subnets** (`10.100.30.0/24`, `10.100.31.0/24`, `10.100.32.0/24`):
   - Dedicated exclusively to stateful persistence layers: Amazon Aurora PostgreSQL, ElastiCache Redis, and Amazon MSK Kafka brokers.
   - Strictly isolated with **no route to the Internet Gateway or NAT Gateways**. Ingress is restricted exclusively to application security groups on explicit database ports (TCP 5432, 6379, 9092/9094).
4. **AWS PrivateLink Endpoints**:
   - VPC Interface Endpoints are deployed across all three AZs for internal AWS services: Amazon S3, AWS Secrets Manager, AWS KMS, Amazon CloudWatch Logs, and AWS STS. This guarantees that internal management traffic never traverses the public internet, satisfying PCI-DSS Requirement 1.3.

---

## 3. Microservice Application Topology (Compute Layer)

The compute tier runs on Amazon Elastic Kubernetes Service (EKS) cluster `paysecure-mumbai-prod` running Kubernetes v1.28. The cluster encompasses 24 worker nodes (`m6i.2xlarge`, 8 vCPU, 32 GiB RAM) evenly distributed across the three availability zones (8 nodes per AZ).

```
                             [ Route 53: api.paysecure.in ]
                                          │
                                    (HTTPS: 443)
                                          ▼
                            [ Internet-facing Dual ALB ]
                            [ AWS WAFv2 Inspection Rules]
                                          │
                     ┌────────────────────┴───────────────────┐
                     ▼                                        ▼
             (Public Routes)                          (Merchant Portal)
            /api/v1/payments                         /portal/*
                     │                                        │
                     ▼                                        ▼
             [ payment-api ]                          [ merchant-portal ]
             (18 Pods, HPA)                           (6 Pods, HPA)
                     │
     ┌───────────────┼────────────────────────┬──────────────────────┐
     │ (gRPC)        │ (gRPC)                 │ (gRPC)               │ (REST/HTTPS)
     ▼               ▼                        ▼                      ▼
[ rate-limiter ] [ fraud-detection ]  [ tokenisation-service ] [ transaction-processor ]
 (12 Pods)        (16 Pods)            (8 Pods - CDE Isolated)   (24 Pods, HPA)
                                                  │                      │
                                           (AES-256 KMS)                 ▼
                                                  │            [ Amazon MSK Kafka ]
                                                  │            Topics:
                                                  │            - payment-events
                                                  │            - settlement-triggers
                                                  │            - audit-log-events
                                                  │                      │
                     ┌────────────────────────────┼──────────────────────┤
                     ▼                            ▼                      ▼
           [ settlement-engine ]        [ audit-logger ]      [ webhook-dispatcher ]
           (8 Pods)                     (12 Pods)              (16 Pods)
                     │                            │                      │
                     ▼                            ▼                      ▼
           [ reconciliation-worker ]    [ notification-service ] [ health-monitor ]
           (6 Pods)                     (8 Pods)                 (4 Pods)
```

The application is decomposed into **12 specialized microservices** totaling approximately 180 running pods:

| Microservice Name | Pod Count (Base/Max) | Protocol / Port | Primary Responsibility | Dependencies |
| :--- | :---: | :---: | :--- | :--- |
| **`payment-api`** | 18 / 60 | HTTPS (8080) | Public ingress gateway; request validation; idempotency check; authentication | Redis, DynamoDB, `rate-limiter`, `fraud-detection` |
| **`transaction-processor`** | 24 / 80 | gRPC (9090) | Core transaction lifecycle state machine; bank adapter integration; payment dispatch | Aurora PostgreSQL, MSK Kafka, `tokenisation-service` |
| **`settlement-engine`** | 8 / 24 | Internal (8082) | Net merchant settlement calculations; batch generation; nodal account payouts | Aurora PostgreSQL, MSK Kafka, Bank SFTP/APIs |
| **`fraud-detection`** | 16 / 48 | gRPC (9091) | Real-time velocity rules; ML anomaly detection; IP geolocation screening | Redis, DynamoDB, Internal Fraud Engine |
| **`notification-service`** | 8 / 20 | HTTP (8083) | SMS, WhatsApp, and email customer transaction receipt dispatch | Third-party SMS/Email Gateways via NAT GW |
| **`merchant-portal`** | 6 / 15 | HTTPS (8443) | Merchant dashboard UI; API keys management; analytics reports | Aurora (Read Replica), S3, Cognito |
| **`reconciliation-worker`** | 6 / 18 | Batch (8084) | Daily clearing file parsing against NPCI, Visa, and Mastercard clearing logs | S3, Aurora PostgreSQL, SFTP Leased Lines |
| **`audit-logger`** | 12 / 30 | Internal (8085) | Immutable compliance event ingestion; non-repudiation cryptographic signing | S3 Compliance Bucket (Object Lock), CloudWatch |
| **`tokenisation-service`** | 8 / 16 | gRPC (8443 mTLS) | Cardholder PAN storage; token generation; PCI DSS CDE isolated boundary | Dedicated Aurora CDE schema, AWS KMS multi-region key |
| **`webhook-dispatcher`** | 16 / 50 | HTTP (8086) | Asynchronous webhook notifications to merchant endpoints with backoff retry | MSK Kafka (`webhook-deliveries`), Redis |
| **`rate-limiter`** | 12 / 30 | gRPC (9092) | Sliding-window token bucket enforcement per merchant API key and IP | ElastiCache Redis Cluster |
| **`health-monitor`** | 4 / 8 | HTTP (8088) | Synthetic transaction execution; deep health probe reporting for ALB and Route 53 | All services, Aurora, Redis, MSK, DynamoDB |

---

## 4. Database, Caching & Event Streaming Topology

### 4.1 Transactional Database: Amazon Aurora PostgreSQL
- **Engine & Version**: Aurora PostgreSQL 15.4.
- **Topology**: Multi-AZ Cluster across three AZs:
  - **1 x Writer Instance**: `db.r6g.2xlarge` (8 vCPU, 64 GiB RAM) located in `ap-south-1a`.
  - **2 x Reader Replicas**: `db.r6g.2xlarge` located in `ap-south-1b` and `ap-south-1c`.
- **Storage**: Aurora cluster storage auto-scaling up to 128 TiB, replicated 6 ways across 3 AZs at the storage tier.
- **Data Stored**: Transaction ledgers, merchant accounts, settlement ledgers, card tokens, and fee tables.
- **Single Point of Failure Vulnerability**: Although storage is resilient across 3 AZs, the **writer instance is a single point of write failure**. While automated failover to a reader replica takes 60 to 120 seconds, any regional outage across Mumbai halts all database write operations immediately.

### 4.2 Idempotency & Session Management: Amazon DynamoDB
- **Table Name**: `paysecure-idempotency-sessions`
- **Provisioned Capacity**: 10,000 Read Capacity Units (RCU) / 5,000 Write Capacity Units (WCU).
- **Partition Key**: `idempotency_key` (String, SHA-256 hash of merchant_id + order_id).
- **TTL**: 86,400 seconds (24-hour expiration).
- **Current Limitation**: Single-region table. In the event of a Mumbai outage, idempotency state is completely inaccessible, creating catastrophic double-charge risks if an uncoordinated secondary site were activated.

### 4.3 In-Memory Caching: Amazon ElastiCache for Redis
- **Configuration**: Redis 7.1, Cluster Mode Enabled.
- **Topology**: 3 shards with 1 primary and 1 replica per shard (6 nodes total, `cache.r6g.xlarge`).
- **Use Cases**: Merchant API rate limiting counters, active merchant routing configurations, session caches.
- **Persistence**: AOF enabled; replication is strictly asynchronous within Mumbai.

### 4.4 Distributed Event Streaming: Amazon Managed Streaming for Apache Kafka (MSK)
- **Cluster**: 6 brokers (`kafka.m5.2xlarge`) spread 2 per AZ across the three availability zones.
- **Throughput**: ~50,000 msgs/sec peak; 7-day retention policy; storage backed by EBS gp3 (2 TiB per broker).
- **Core Topics**:
  - `payment-events`: 36 partitions, replication factor 3, min.insync.replicas 2.
  - `settlement-triggers`: 18 partitions, replication factor 3.
  - `webhook-deliveries`: 24 partitions, replication factor 3.
  - `audit-log-events`: 36 partitions, replication factor 3.
- **Current Limitation**: Message stream exists exclusively inside `ap-south-1`. No cross-region replication or mirroring exists.

---

## 5. Security Architecture & PCI-DSS Compliance Boundary

```
+-----------------------------------------------------------------------------------------------+
| PCI-DSS LEVEL 1 COMPLIANCE BOUNDARY (ap-south-1 Mumbai)                                       |
|                                                                                               |
|  [ Non-CDE VPC Zone: General Microservices ]                                                 |
|  - payment-api, merchant-portal, notification-service                                         |
|  - settlement-engine, reconciliation-worker                                                   |
|                                 │                                                             |
|                          (mTLS / TLS 1.3)                                                     |
|                     gRPC Port 8443 with Client Cert                                           |
|                                 ▼                                                             |
|  +-----------------------------------------------------------------------------------------+  |
|  | CDE Segment (Cardholder Data Environment): Kubernetes Namespace: `paysecure-cde`        |  |
|  | NetworkPolicy: Deny-All Ingress except payment-api on TCP 8443                          |  |
|  |                                                                                         |  |
|  |  [ tokenisation-service ] ◄────────► [ Dedicated RDS Schema / Vault ]                  |  |
|  |  (Stateless Pods)                    (AES-256 Envelope Encryption)                      |  |
|  |           │                                      │                                      |  |
|  |           └──────────────┐        ┌──────────────┘                                      |  |
|  |                          ▼        ▼                                                     |  |
|  |              [ AWS KMS Multi-Region Primary Key ]                                       |  |
|  |              Key ID: mrk-paysecure-cde-mumbai-master                                    |  |
|  +-----------------------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------------------+
```

1. **Cardholder Data Environment (CDE) Isolation**:
   - The `tokenisation-service` is strictly quarantined in the Kubernetes namespace `paysecure-cde`.
   - Kubernetes `NetworkPolicy` isolates CDE pods: only `payment-api` pods presenting verified mTLS certificates can communicate with the tokenisation service.
   - Raw Card Primary Account Numbers (PAN) and CVVs are tokenized in memory and never written to general database tables.
2. **Cryptographic Key Management**:
   - AWS KMS Customer Managed Keys (CMK) enforce envelope encryption for Aurora storage, DynamoDB tables, MSK Kafka topics, and S3 compliance buckets.
   - Database credentials and partner bank API certificates reside in AWS Secrets Manager with automatic 90-day Lambda rotation.
3. **Audit Logging & Non-Repudiation**:
   - Every API invocation is recorded in AWS CloudTrail and ingested into Amazon S3 with AWS Object Lock in Compliance Mode for a mandatory 7-year retention period as prescribed by RBI and Section 43A of the IT Act.

---

## 6. Identification of Single Points of Failure (SPOFs)

Despite adopting multi-AZ redundancy inside Mumbai, the current architecture suffers from **seven catastrophic Single Points of Failure**:

| # | Component / Domain | Single Point of Failure Mechanism | Business Impact | Estimated Downtime |
| :-: | :--- | :--- | :--- | :--- |
| **SPOF-1** | **AWS Region (`ap-south-1`)** | Total regional outage (power grid collapse, major undersea cable severance, wide-scale AWS control-plane failure). | **100% Platform Blackout**. Zero transaction processing across all 45,000 merchants. Regulatory violation of RBI mandates. | 4 to 24+ Hours (Indefinite manual recovery) |
| **SPOF-2** | **Aurora PostgreSQL Single Writer** | Loss of `ap-south-1a` writer or storage synchronization lockup. Writer failover to reader takes 60–120s. | Transaction writes fail during failover window. In-flight transactions drop into an ambiguous state. | 1 to 5 Minutes |
| **SPOF-3** | **Global DNS Entrypoint** | `api.paysecure.in` configured with a single Route 53 A-record Alias pointing exclusively to Mumbai ALB. | No secondary endpoint exists. Client DNS queries fail immediately if ALB or regional Route 53 resolvers degrade. | Indefinite until manual DNS edit |
| **SPOF-4** | **DynamoDB Idempotency Store** | Single-region table without Global Table replication. | Failover to another region without session data leads to **duplicate payments / double-spending**. | Indefinite until data export |
| **SPOF-5** | **MSK Kafka Broker Fleet** | Single MSK cluster in Mumbai. Asynchronous settlement events, audit logs, and webhooks are trapped locally. | Financial reconciliation failure; merchants receive no webhook updates; delayed bank settlements. | Hours to Days |
| **SPOF-6** | **AWS KMS Single-Region Keys** | KMS master keys exist exclusively in `ap-south-1`. Secondary region cannot decrypt database snapshots or backups. | Even if secondary infrastructure is spun up, encrypted data remains completely unrecoverable. | Permanent Data Loss if key lost |
| **SPOF-7** | **Partner Bank Leased Lines** | AWS Direct Connect / IPsec VPN tunnels terminate at a single Mumbai Transit Gateway. | Primary bank connections (HDFC, ICICI, SBI) severed during regional network partition. | Hours to Days |

---

## 7. Operational Baseline Metrics & Uptime Deficit

- **Current Uptime**: 99.92% over the trailing 12 months.
- **Cumulative Annual Downtime**: **7.008 hours** (420.5 minutes).
- **Target Uptime (Q3 2026 Mandate)**: **99.99%** (Maximum allowable downtime: **52.56 minutes/year** across both planned and unplanned outages).
- **Downtime Gap to Close**: **6.13 hours of downtime must be eliminated** annually through automated cross-region disaster recovery, reducing regional RTO from hours to `< 5 minutes` and RPO to `< 1 minute`.
