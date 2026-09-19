# PaySecure Gateway: Disaster Recovery Cost Summary & TCO Modeling

**Document ID**: PSG-FIN-001  
**Baseline Spend**: ₹8.00 Crore INR/year (~$960,000 USD)  
**Approved Budget Multiplier**: 1.4x to 1.65x (₹11.20 Cr to ₹13.20 Cr)  
**Target Tier**: Hot Standby (ap-south-1 Mumbai + ap-south-2 Hyderabad)  
**Classification**: Strictly Confidential - Executive Finance & Cloud Economics  

---

## 1. Executive Cost Summary

PaySecure Gateway operates a high-throughput financial transaction processing engine requiring continuous compute, multi-AZ database clustering, and high-volume message streaming. Expanding from single-region Mumbai to a resilient multi-region deployment inevitably increases annual infrastructure spend.

This document synthesizes the multi-tier financial model detailed in [`cost-model.xlsx`](./cost-model.xlsx), comparing four disaster recovery architectures against the current single-region baseline:

```
+---------------------------------------------------------------------------------------------------+
| Multi-Region Disaster Recovery TCO Summary Table                                                  |
+--------------------------+--------------------+---------------------+-------------------+---------+
| Architecture Tier        | Monthly Spend ($)  | Annual Spend (INR)  | Cost Multiplier   | Status  |
+--------------------------+--------------------+---------------------+-------------------+---------+
| Current Single-Region    | $80,000 USD        | ₹8.00 Crore INR     | 1.00x Baseline    | Legacy  |
| Cold Standby (Pilot)     | $86,400 USD        | ₹8.64 Crore INR     | 1.08x Multiplier  | Reject  |
| Warm Standby             | $112,000 USD       | ₹11.20 Crore INR    | 1.40x Multiplier  | Viable  |
| Hot Standby [RECOMMENDED]| $129,800 USD       | ₹12.98 Crore INR    | 1.62x Multiplier  | APPROVED|
| Active-Active            | $164,200 USD       | ₹16.42 Crore INR    | 2.05x Multiplier  | Exceeds |
+--------------------------+--------------------+---------------------+-------------------+---------+
```

---

## 2. Line-Item Cost Architecture across 17 Service Categories

The financial model categorizes infrastructure costs across 17 distinct service components:

1. **Compute Fleet (Amazon EKS)**:
   - Primary Region: 24 worker nodes (`m6i.2xlarge`) = $21,500/month.
   - Secondary Standby Region: Pre-warmed fleet of 12 worker nodes (50% compute standby) running ~60 pods = $13,000/month. Total EKS monthly spend: **$34,500/month**.
2. **Database Layer (Aurora PostgreSQL Global Database)**:
   - Mumbai: 1 Writer + 2 Reader instances (`db.r6g.2xlarge`) = $18,200/month.
   - Hyderabad: 1 Reader instance continuously online to facilitate rapid 75-second writer promotion = $9,200/month. Total Aurora instance spend: **$27,400/month**.
   - Storage replication and replicated I/O: $9,200/month.
3. **Session & Idempotency Store (DynamoDB Global Tables)**:
   - Provisioned 10,000 RCU / 5,000 WCU replicated across Mumbai and Hyderabad using Replicated Write Capacity Units (rWCUs) at $0.00075/rWCU-hour + replication data transfer = **$10,800/month**.
4. **Caching Tier (ElastiCache Redis Global Datastore)**:
   - 3 shards (6 nodes) in Mumbai primary + 3 shards (6 nodes) read-only in Hyderabad = **$7,800/month**.
5. **Event Streaming (Amazon MSK Kafka)**:
   - 6 brokers in Mumbai + 6 brokers in Hyderabad + AWS MSK Replicator managed instances = **$12,400/month**.
6. **Network & Ingress**:
   - Dual ALBs, WAFv2 WebACLs, AWS Shield Advanced, and Route 53 health checking = **$9,200/month**.
   - AWS Inter-Region Transit Gateway (100 Gbps dark fiber attachment) + cross-region data transfer (~155 TB/month at $0.02/GB) = **$8,300/month**.

---

## 3. Cost Optimization Strategies (Achieving the 1.62x Multiplier)

To satisfy the External Big Four Auditor and VP Engineering constraints, PaySecure achieves an annual savings of **₹3.38 Crore INR** through structured cloud financial engineering:

1. **3-Year Compute Savings Plans**:
   - Committing to 3-year All-Upfront Compute Savings Plans for baseline EKS worker nodes delivers a **44% discount** over on-demand rates, saving $15,180/month (₹1.52 Cr/year).
2. **Aurora PostgreSQL Reserved Instances (3-Year No-Upfront)**:
   - Reserving the 4 `db.r6g.2xlarge` instances across Mumbai and Hyderabad yields a **40% discount**, saving $10,960/month (₹1.10 Cr/year).
3. **DynamoDB Reserved Capacity**:
   - Committing to 10,000 RCU and 5,000 WCU via 3-year Reserved Capacity delivers a **45% reduction** in write unit pricing, saving $4,860/month (₹49 Lakh/year).
4. **Automated Non-Production Standby Downscaling**:
   - Staging and QA environments in Hyderabad are completely spun down outside 09:00 - 19:00 business hours using Kubernetes CronJobs, saving $4,200/month.
