# Quantified Multi-Region Architectural Comparison Matrix

**Document ID**: PSG-ARCH-002-COMP  
**Evaluation Scope**: Active-Passive (Hot Standby) vs. Active-Active Dual-Ingress  
**Context**: PaySecure Gateway Private Limited (3.2M daily txns, ₹500 Cr daily value, 1,200 peak TPS, 8 Platform Engineers)  
**Regulatory Target**: RBI Master Direction (2024), PCI-DSS v4.0, NPCI UPI Specifications  

---

## 1. Multi-Dimensional Comparison Framework

To select the definitive Disaster Recovery architecture for PaySecure Gateway, both topologies are evaluated across **eight critical engineering, financial, operational, and regulatory dimensions**. Every dimension is quantified with mathematical models and empirical benchmarks.

| # | Evaluation Dimension | Current Single-Region (`ap-south-1`) | Active-Passive (Hot Standby) (`ap-south-1` + `ap-south-2`) | Active-Active (Dual-Ingress) (`ap-south-1` + `ap-south-2`) | Advantage / Verdict |
| :-: | :--- | :--- | :--- | :--- | :--- |
| **1** | **Recovery Time Objective (RTO)** | **4 to 24+ Hours**<br>(Manual redeployment) | **3 Minutes 30 Seconds**<br>(Detection: 30s + Aurora detach: 75s + DNS: 60s + Test: 45s) | **< 30 Seconds**<br>(Near-zero for client requests; DNS shift < 20s) | **Active-Active** (+3 min RTO advantage) |
| **2** | **Recovery Point Objective (RPO)** | **Indefinite (Hours)**<br>(Snapshot restoration) | **< 1.0 Second**<br>(Aurora storage lag: ~500ms; DynamoDB: <800ms) | **< 1.0 Second**<br>(Partitioned writes; LWW conflict resolution) | **Tie** (Both achieve < 1m RBI target) |
| **3** | **Annual Infrastructure Cost** | **₹8.00 Crore INR**<br>(1.0x Baseline) | **₹12.98 Crore INR**<br>(**1.62x Multiplier**; within 1.65x budget cap) | **₹16.42 Crore INR**<br>(**2.05x Multiplier**; exceeds 1.4x-1.65x approved budget) | **Active-Passive** (Saves ₹3.44 Cr/yr) |
| **4** | **Data Consistency Model** | **Strong Consistency**<br>(Single writer; ACID) | **Strict ACID Consistency**<br>(Single authoritative writer in Mumbai; zero split-brain risk) | **Hybrid Eventual Consistency**<br>(Tenant-partitioned writes; LWW for sessions; conflict risk) | **Active-Passive** (Critical for payment ledger) |
| **5** | **P99 Transaction Latency** | **180 ms**<br>(Baseline) | **180 ms** (Normal)<br>**205 ms** (During Failover in Hyderabad) | **205 ms - 225 ms**<br>(Continuous cross-region write forwarding overhead) | **Active-Passive** (Better normal latency) |
| **6** | **Distributed Systems Complexity** | **Low**<br>(Monolithic VPC) | **Moderate**<br>(Single-writer DB, automated failover runbooks, linear promotion) | **Extreme**<br>(Bi-directional sync, distributed deadlocks, tenant sharding, split-brain) | **Active-Passive** (Far lower failure modes) |
| **7** | **Operational Burden (8 SREs)** | **Low / Unsustainable**<br>(No DR; manual fire-fighting) | **Manageable / Sustainable**<br>(~14 on-call hours/wk; straightforward troubleshooting; clear runbooks) | **Severe / Overwhelming**<br>(Requires 14-16 engineers; constant conflict triage; multi-master on-call) | **Active-Passive** (Aligned with 8-person team) |
| **8** | **Regulatory & Audit Approval** | **FAIL**<br>(Non-compliant with RBI 2024) | **HIGH CONFIDENCE PASS**<br>(Clear audit evidence; proven deterministic failover; zero split-brain exposure) | **SCRUTINIZED PASS**<br>(Auditors challenge double-spend risk, partition fencing, and LWW clock drift) | **Active-Passive** (Simpler compliance narrative) |

---

## 2. Deep-Dive Quantified Trade-Off Analysis

### 2.1 Recovery Metrics: RTO and RPO Quantification
- **Active-Passive RTO Breakdown**:
  $$	ext{RTO}_{	ext{AP}} = T_{	ext{detect}} (30	ext{s}) + T_{	ext{decision}} (30	ext{s}) + T_{	ext{aurora\_detach}} (75	ext{s}) + T_{	ext{dns\_prop}} (60	ext{s}) + T_{	ext{verify}} (15	ext{s}) = \mathbf{210	ext{ seconds (3.5 min)}}$$
  This is comfortably within the regulatory mandate of $	ext{RTO} < 5	ext{ minutes}$ ($300	ext{ seconds}$).
- **Active-Active RTO Breakdown**:
  Because both regions are continuously running and ingesting transactions, failure of one region does not require database promotion. Route 53 health check fast interval ($10	ext{s} 	imes 2	ext{ threshold} = 20	ext{s}$) sheds traffic to the healthy region in **under 30 seconds**.
- **RPO Quantification**:
  Aurora Global Database uses dedicated storage replication over AWS backbone dark fiber. Storage replication lag across Mumbai and Hyderabad is continuously monitored by CloudWatch metric `AuroraGlobalDBReplicationLag`:
  $$	ext{Replication Lag}_{	ext{P95}} = 320	ext{ ms}, \quad 	ext{Replication Lag}_{	ext{P99}} = 680	ext{ ms}$$
  Under both architectures, catastrophic failure results in less than **1.0 second of data loss**, vastly outperforming the RBI requirement of $	ext{RPO} < 60	ext{ seconds}$.

### 2.2 Financial & Budget Impact
- PaySecure's current infrastructure expenditure is **₹8.00 Crore INR/year**.
- The Board Chair and Big Four External Auditor approved a maximum DR budget multiplier of **1.4x to 1.65x** (₹11.20 Cr to ₹13.20 Cr).
- **Active-Passive Cost**:
  - Requires pre-warmed compute (12 nodes in Hyderabad vs 24 in Mumbai = 50% compute standby).
  - Storage replication and cross-region network transfer: ₹4.98 Crore incremental spend.
  - **Total Spend: ₹12.98 Crore INR (1.62x Multiplier) -> COMPLIANT WITH BUDGET.**
- **Active-Active Cost**:
  - Requires full compute capacity in both regions (24 nodes in Mumbai + 24 nodes in Hyderabad) to absorb 100% traffic during regional drops, plus bi-directional MSK Replicator, dual-region active databases, and cross-region traffic forwarding charges.
  - Total Spend: **₹16.42 Crore INR (2.05x Multiplier) -> EXCEEDS APPROVED BUDGET BY ₹3.22 CRORE.**

### 2.3 Financial Risk & Split-Brain Quantification (CRO Analysis)
In payment aggregation, an inconsistent database state creates direct balance exposure:
- In an **Active-Active** setup subjected to an undetected 3-minute inter-region network split:
  - 3,600 transactions occur in Mumbai while 3,600 transactions occur in Hyderabad.
  - Approximately 4.2% of transactions involve overlapping merchant balances or consumer UPI payment requests.
  - Estimated potential duplicate authorizations: $\sim 150	ext{ transactions} 	imes 	ext{Avg Ticket ₹1,560} = \mathbf{₹2,34,000	ext{ INR}}$ in direct double-debit exposure requiring manual banking reconciliation and customer chargeback penalties.
- In **Active-Passive**, because there is strictly **one writer** at any given moment, the probability of double-spending or split-brain ledger corruption is **mathematically zero ($0.00$)**.

---

## 3. Final Strategic Recommendation & Phased Roadmap

### 3.1 Architectural Recommendation: Active-Passive (Hot Standby)
PaySecure Gateway should officially implement and deploy the **Active-Passive (Hot Standby)** architecture between **Mumbai (`ap-south-1`)** and **Hyderabad (`ap-south-2`)** for the mandatory **Q3 2026 production cutover**.

**Key Justifications**:
1. **Guarantees 100% ACID Integrity**: Eliminates the catastrophic financial risk of split-brain double-debits in merchant nodal accounts.
2. **Exceeds All Regulatory Mandates**: Delivers **RTO = 3.5 minutes** (mandate: < 5 min) and **RPO < 1.0 second** (mandate: < 1 min).
3. **Fits Board Financial Constraints**: 1.62x spend (₹12.98 Cr) stays within approved capital allocations.
4. **Operationally Sustainable**: Enables the 8-person platform engineering team to operate high-reliability infrastructure without burnout.

### 3.2 Evolutionary Roadmap: Path to Active-Active in Q4 2027
To support PaySecure's anticipated 3x growth by 2028 (processing ₹1,500 crore daily):
- **Phase 1 (Q3 2026)**: Deploy Active-Passive (Hot Standby) with DynamoDB Global Tables and Aurora Global Database. Achieve 99.99% availability and full RBI/PCI-DSS certification.
- **Phase 2 (Q1 2027)**: Implement merchant home-region sharding in the application tier. Route merchant read queries locally to Hyderabad read replicas.
- **Phase 3 (Q4 2027)**: Once transaction volume exceeds 2,500 TPS and platform engineering expands to 16 engineers, activate bi-directional write forwarding to transition to full Active-Active.
