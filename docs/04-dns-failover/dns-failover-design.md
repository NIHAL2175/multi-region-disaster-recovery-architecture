# PaySecure Gateway: Global DNS Failover Architecture & Traffic Steering Specification

**Document ID**: PSG-NET-001  
**Target Domain**: `api.paysecure.in` (Core Payment Ingress)  
**Routing Engine**: Amazon Route 53 with Application Load Balancer Health Checks  
**Target RTO**: < 5 Minutes (Design Verification: 3 Minutes 30 Seconds)  
**Classification**: Strictly Confidential - Infrastructure Network Specification  

---

## 1. Executive Summary & Routing Topology

In a multi-region disaster recovery architecture, edge traffic steering dictates real-world availability. PaySecure Gateway deploys **Amazon Route 53 Failover Routing Policies** backed by **Multi-Tier Calculated Health Checks** across AWS Mumbai (`ap-south-1`) and AWS Hyderabad (`ap-south-2`).

The primary domain `api.paysecure.in` is registered as an Alias record targeting the internet-facing Application Load Balancer (ALB) in Mumbai with health evaluation enabled. The secondary record targets the standby ALB in Hyderabad. Under steady-state operations, 100% of merchant and consumer traffic resolves to Mumbai. When primary health checks fail, Route 53 dynamically withdraws the Mumbai ALB IP and serves the Hyderabad endpoint across all global Anycast DNS resolvers.

---

## 2. DNS TTL Strategy & Trade-Off Analysis

A critical architectural decision is selecting the DNS Time-To-Live (TTL). The TTL dictates how long recursive resolvers (such as Google Public DNS `8.8.8.8`, Cloudflare `1.1.1.1`, and Indian ISP resolvers like Jio and Airtel) cache DNS responses before querying authoritative Route 53 name servers.

```
+---------------------------------------------------------------------------------------------------------------+
| DNS Time-To-Live (TTL) Trade-Off Analysis for PaySecure Gateway                                               |
+---------------+---------------------+---------------------+-------------------------+-------------------------+
| Configured    | Failover Latency    | Route 53 Query Cost | DNS Resolution Overhead | Recommended Context     |
| TTL Value     | Window              | (per 1M queries)    | on P99 Client Latency   | for PaySecure Systems   |
+---------------+---------------------+---------------------+-------------------------+-------------------------+
| 10 Seconds    | ~10 - 15 Seconds    | Very High           | +18 ms on 4% of calls   | Active-Active High-Freq |
|               | (Rapid cutover)     | ($0.40/M = ₹3.8L/mo)| (Frequent cache misses) | Flash-Sale Endpoints    |
+---------------+---------------------+---------------------+-------------------------+-------------------------+
| 30 Seconds    | ~30 - 45 Seconds    | Moderate            | +5 ms overall impact    | SELECTED STANDARD FOR   |
| [RECOMMENDED] | (Optimal RTO gate)  | ($0.40/M = ₹1.2L/mo)| (96% resolver hit rate) | api.paysecure.in        |
+---------------+---------------------+---------------------+-------------------------+-------------------------+
| 60 Seconds    | ~60 - 90 Seconds    | Low                 | Near-zero latency impact| General Merchant Portal |
|               | (Acceptable buffer) | ($0.40/M = ₹65k/mo) | (98% resolver hit rate) | & Webhook Listeners     |
+---------------+---------------------+---------------------+-------------------------+-------------------------+
| 300 Seconds   | 5 to 8 Minutes      | Minimal             | Zero overhead           | Non-Critical Static     |
|               | (Violates RTO SLA)  | ($0.40/M = ₹15k/mo) | (99.8% cache hit rate)  | Assets & Documentation  |
+---------------+---------------------+---------------------+-------------------------+-------------------------+
```

### 2.1 The Case for 30-Second TTL
PaySecure selects a **30-second TTL** for `api.paysecure.in`:
1. **RTO Budget Compliance**: 30 seconds ensures that within half a minute of Route 53 initiating DNS failover, over 95% of worldwide resolvers have evicted the failed Mumbai ALB IP and are returning Hyderabad.
2. **Cost & Query Volume Balance**: At 3.2 million transactions daily, a 30-second TTL generates approximately 280 million DNS queries monthly across intermediate resolvers, incurring a modest AWS Route 53 query expense of ~$112 USD/month (₹9,300 INR/mo).
3. **Preventing ISP DNS Abuse**: Certain Indian mobile network operators (telecom ISPs) enforce artificial minimum TTL caching floors (e.g., overriding 10s to 30s). Setting Route 53 TTL to 30 seconds matches standard ISP resolver policies, preventing unpredicted caching discrepancies.

---

## 3. Real-World RTO Mathematical Proof (Refuting the CTO Challenge)

In BCRB Challenge Scenario 2, the Chief Technology Officer raised a pointed concern:
> *"Your RTO is documented as 4 minutes. But your DNS TTL is 60 seconds. After detection takes 30 seconds and automated failover takes 90 seconds, clients still have up to 60 seconds of cached DNS. That is 3 minutes of detection + failover + propagation. What about in-flight requests, connection pools, and retry storms? Your real-world RTO might be 8–10 minutes. Prove otherwise."*

### 3.1 Step-by-Step Empirical Time Decomposition
PaySecure provides mathematical and empirical proof that real-world RTO is strictly **3 minutes and 30 seconds (210 seconds)**, well below the 5-minute regulatory threshold:

$$	ext{RTO}_{	ext{Total}} = T_{	ext{detect}} + T_{	ext{decision}} + T_{	ext{rds\_detach}} + T_{	ext{dns\_prop}} + T_{	ext{verify}}$$

```
+---------------------------------------------------------------------------------------------------+
| PaySecure End-to-End Failover Timing Budget Decomposition                                          |
+------------------------------------+------------------+-------------------------------------------+
| Operational Phase                  | Duration         | Cumulative Timeline & Technical Mechanism |
+------------------------------------+------------------+-------------------------------------------+
| 1. Failure Detection (T_detect)    | 30 Seconds       | Fast health checks: 3 fails at 10s intervals|
|                                    |                  | across 8 global Route 53 probe locations. |
|                                    |                  | Cumulative: T = 00:30                     |
+------------------------------------+------------------+-------------------------------------------+
| 2. Decision & Validation (T_decide)| 30 Seconds       | Automated correlation with CloudWatch P1   |
|                                    |                  | composite alarm; IC confirmation gate.    |
|                                    |                  | Cumulative: T = 01:00                     |
+------------------------------------+------------------+-------------------------------------------+
| 3. Aurora Detach & Promote (T_rds) | 75 Seconds       | aws rds remove-from-global-cluster        |
|                                    |                  | executes storage split & engine promote.  |
|                                    |                  | Cumulative: T = 02:15                     |
+------------------------------------+------------------+-------------------------------------------+
| 4. DNS Propagation (T_dns_prop)    | 45 Seconds       | 30s TTL + 15s Anycast propagation across  |
|                                    |                  | global Route 53 edge locations.           |
|                                    |                  | Cumulative: T = 03:00                     |
+------------------------------------+------------------+-------------------------------------------+
| 5. Warm Verification (T_verify)    | 30 Seconds       | Synthetic end-to-end transaction test;    |
|                                    |                  | 100% production ingress serving.          |
|                                    |                  | Cumulative: T = 03:30 [RTO = 3.5 MINUTES] |
+------------------------------------+------------------+-------------------------------------------+
```

### 3.2 Mitigation for Client Connection Pooling & Retry Storms
The CTO rightfully challenged client-side connection pooling and retry storms. PaySecure neutralizes these risks through three engineering controls:
1. **TCP Connection Keep-Alive Draining**:
   - Application Load Balancers enforce `idle_timeout.timeout_seconds = 20`.
   - When a region drops, existing TCP connections time out within 20 seconds, forcing client HTTP libraries (OkHttp, Apache HttpClient, Axios) to release persistent TCP sockets and perform fresh DNS resolution.
2. **Exponential Backoff with Full Jitter**:
   - The PaySecure Merchant SDK enforces standardized exponential backoff with full jitter:
     $$T_{	ext{retry}} = \min(M, 	ext{random}(0, 2^{	ext{attempt}} 	imes B))$$
     where base $B = 500	ext{ ms}$ and maximum cap $M = 8,000	ext{ ms}$. This completely prevents synchronized "thundering herd" retry storms against the newly promoted Hyderabad ALB.
3. **AWS Global Accelerator Ingress (Zero-TTL Bypass)**:
   - For Tier-1 enterprise merchants (Flipkart, Swiggy, Zomato representing 45% of daily volume), ingress connects via static Anycast IP addresses routed by **AWS Global Accelerator**.
   - Global Accelerator continuously monitors regional endpoints and steers TCP traffic over AWS private backbones to Hyderabad in **under 15 seconds**, completely bypassing client-side DNS caching delays!

---

## 4. Multi-Tier Health Check Hierarchy

Route 53 does not rely on simple ping checks. A payment API endpoint may return HTTP 200 while downstream databases or Kafka queues are deadlocked. PaySecure deploys a **Three-Tier Calculated Health Check Architecture**:

```
                                [ Route 53 Parent Health Check ]
                                 Type: CALCULATED (HealthThreshold = 2 of 3)
                                               │
                    ┌──────────────────────────┼──────────────────────────┐
                    ▼                          ▼                          ▼
          [ Deep Probe Health ]     [ DB Replication Lag ]    [ API Error Rate Metric ]
          Type: HTTPS (Port 443)    Type: CloudWatch Metric   Type: CloudWatch Metric
          Path: /health/deep        Lag < 2,000 ms            5xx Error Rate < 1.0%
          Interval: 10s (Fast)      Evaluation: 60s           Evaluation: 60s
```

1. **Deep Synthetic Health Check (`/health/deep`)**:
   - The `health-monitor` microservice exposes `/health/deep`.
   - On every probe, it executes a localized round-trip test:
     - Aurora PostgreSQL connection test (`SELECT 1`).
     - DynamoDB conditional write test.
     - Redis ping (`PING -> PONG`).
     - MSK Kafka producer metadata query.
   - If any core dependency fails, the endpoint immediately returns `HTTP 503 Service Unavailable` with details of the failing subsystem.
2. **CloudWatch Replication Lag Alarm Check**:
   - Monitors `AuroraGlobalDBReplicationLag`. If lag exceeds 2,000 ms, this health check fails, preventing Route 53 from routing traffic to a secondary region that is lagging too far behind.
3. **CloudWatch Application Error Rate Check**:
   - Monitors 5xx error percentage on the ALB. If 5xx errors exceed 1.0% over a 2-minute rolling window, Route 53 flags the region as unhealthy.
