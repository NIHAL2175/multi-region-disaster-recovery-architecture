# Multi-Region Disaster Recovery Architecture Payment Systems

> **Author** : Nihal N  
> **Track** : DevOps & Cloud Engineer  
> **Category** : Disaster Recovery Architecture   

---

## 1. Executive Summary & Regulatory Context

PaySecure Gateway currently operates on a single AWS region (`ap-south-1`, Mumbai) delivering 99.92% trailing uptime (accumulating ~7 hours of annual downtime). Under regulatory directives from the **Reserve Bank of India (RBI Master Direction on Payment Systems 2024)**, **NPCI UPI Technical Standards**, and **PCI DSS v4.0**, PaySecure must achieve **99.99% service availability** by Q3 2026, with:
- **Recovery Point Objective (RPO)**: `< 1 minute` (transactional zero-data-loss for committed payments).
- **Recovery Time Objective (RTO)**: `< 5 minutes` (end-to-end detection, DNS propagation, and traffic switchover).
- **Strict Data Sovereignty**: All primary and replicated transaction/cardholder data strictly confined within Indian territory (`ap-south-1` Mumbai and `ap-south-2` Hyderabad).

---

## 2. Operational Profile Baseline

| Operational Parameter | Baseline Specification | Business & Engineering Impact |
| :--- | :--- | :--- |
| **Daily Transaction Volume** | ~3,200,000 txns/day | Average ~250 TPS (peak business hours), requires high-throughput streaming |
| **Daily Transaction Value** | ₹500 crore INR (~$60M USD) | Hourly turnover of ₹20.83 crore; ₹37.5 lakh revenue/hr (at 1.8% MDR) |
| **Peak Throughput** | 1,200 TPS | Festival sale surges (Diwali, Big Billion Days) demand dynamic scaling |
| **Latency Budget (P99)** | 180 ms end-to-end | NPCI strict ceiling is < 300 ms; cross-region budget is capped at 30 ms |
| **Active Merchants** | 45,000 accounts | SLA credit exposure and churn risks during cascading failures |
| **Payment Rails** | UPI, Cards, NetBanking, Wallets | UPI represents 68% of volume; cardholder data subject to PCI-DSS CDE scope |
| **Engineering Team** | 42 total (8 platform/SRE) | On-call sustainability demands automated failover with manual confirmation gate |
| **Current Baseline Spend** | ₹8 crore INR/year | Board-approved DR budget multiplier is 1.4x - 1.65x |

---

## 3. Repository Directory Structure

```
doc-5b-multi-region-dr/
├── README.md                           # Main engineering index and executive overview
├── CHANGELOG.md                        # Versioning and architectural revision log
├── docs/
│   ├── 01-current-state/               # Baseline single-region architecture specification
│   │   ├── current-architecture.md     # Deep dive into Mumbai deployment & SPOFs (>800 words)
│   │   ├── architecture-diagram.drawio # Draw.io source file with standard AWS icons
│   │   └── architecture-diagram.png    # High-resolution architectural diagram export
│   ├── 02-multi-region-design/         # Dual multi-region architectural evaluations
│   │   ├── active-passive-design.md    # Active-Passive (Hot Standby) design doc (>2,000 words)
│   │   ├── active-active-design.md     # Active-Active dual-ingress design doc (>2,000 words)
│   │   ├── comparison-matrix.md        # Quantified 8+ dimension comparative framework
│   │   ├── active-passive-diagram.drawio
│   │   ├── active-passive-diagram.png
│   │   ├── active-active-diagram.drawio
│   │   └── active-active-diagram.png
│   ├── 03-data-replication/            # Stateful data replication engineering
│   │   ├── replication-strategy.md     # Aurora, DynamoDB, Redis, Kafka, S3 analysis (>1,500 words)
│   │   └── sequence-diagrams.md        # Mermaid diagrams (write, read, failover, reconcile)
│   ├── 04-dns-failover/                # Routing, health checks, and edge traffic steering
│   │   ├── dns-failover-design.md      # Route 53 health checking, TTL & propagation (>800 words)
│   │   ├── health-check-config.yaml    # Production-ready Route 53 health check specification
│   │   ├── route53-config.json         # Route 53 DNS failover record payload
│   │   └── failover-timing-diagram.md  # Step-by-step failover latency decomposition
│   ├── 05-runbooks/                    # 12 Command-level production disaster recovery runbooks
│   │   ├── RB-01-complete-region-failure.md
│   │   ├── RB-02-database-corruption.md
│   │   ├── RB-03-dns-poisoning.md
│   │   ├── RB-04-kafka-cluster-failure.md
│   │   ├── RB-05-network-partition.md
│   │   ├── RB-06-cryptographic-key-compromise.md
│   │   ├── RB-07-ddos-attack.md
│   │   ├── RB-08-third-party-npci-outage.md
│   │   ├── RB-09-tls-certificate-expiry.md
│   │   ├── RB-10-single-az-power-failure.md
│   │   ├── RB-11-ransomware-attack.md
│   │   └── RB-12-cascading-microservice-failure.md
│   ├── 06-cost-analysis/               # Financial modeling and TCO
│   │   ├── cost-model.xlsx             # Dynamic multi-sheet Excel model across 4 DR tiers
│   │   ├── cost-summary.md             # Cost breakdown, trade-offs, and optimization strategies
│   │   └── roi-analysis.md             # Downtime losses (₹37.5L/hr) vs. DR investment ROI
│   ├── 07-data-sovereignty/            # Regulatory and data residency mapping
│   │   ├── compliance-matrix.md        # RBI, PCI DSS v4.0, NPCI, IT Act 2000 Section 43A
│   │   └── data-flow-diagrams.md       # Cross-region boundary and encryption diagrams
│   ├── 08-dr-drill-plan/               # Business continuity testing and drill schedule
│   │   ├── annual-drill-plan.md        # 12-month calendar (4 full failover, 12 component drills)
│   │   ├── drill-success-criteria.md   # SLA/SLO evaluation gates and scoring rubrics
│   │   └── post-drill-template.md      # Post-Incident Review (PIR) and audit record template
│   ├── 09-bcrb-defense/                # Business Continuity Review Board Defense
│   │   └── bcrb-stakeholder-defense.md # Answers to 10 pointed challenge questions (CTO, CRO, etc.)
│   ├── 10-sandbox-advanced/            # Advanced research and stretch goals
│   │   ├── chaos-engineering.md        # 6 Chaos engineering experiments with blast radius control
│   │   ├── multi-cloud-dr.md           # AWS + GCP multi-cloud DR feasibility & 15+ service map
│   │   ├── automated-failover-engine.md# Heuristic multi-signal failover decision engine
│   │   ├── zero-downtime-migration.md  # Blue-green cross-region migration workflow
│   │   └── financial-var-model.md      # Quantitative Value-at-Risk (VaR) downtime model
│   └── deliberate-errors-found.md      # Audit of 5 deliberate errors in the original project brief
├── configs/
│   ├── terraform/                      # Infrastructure as Code (Terraform 1.5+)
│   │   ├── main.tf                     # Root module orchestrating Mumbai & Hyderabad
│   │   ├── variables.tf                # Typed input variables
│   │   ├── outputs.tf                  # Infrastructure outputs (endpoints, ARNs)
│   │   ├── terraform.tfvars.example    # Configuration example
│   │   └── modules/                    # 9 Reusable Terraform modules
│   │       ├── networking/             # Multi-region VPCs & Inter-Region Transit Gateway
│   │       ├── compute/                # Dual EKS clusters, node groups & IRSA
│   │       ├── database/               # Aurora PostgreSQL Global Database
│   │       ├── dynamodb/               # DynamoDB Global Tables with replication
│   │       ├── cache/                  # ElastiCache Redis Global Datastore
│   │       ├── messaging/              # Amazon MSK with MSK Replicator
│   │       ├── dns/                    # Route 53 health checks and failover routing
│   │       ├── monitoring/             # Multi-region CloudWatch alarms & synthetics
│   │       └── security/               # Multi-region KMS, WAFv2 & Shield Advanced
│   ├── kubernetes/                     # Production Kubernetes manifests
│   │   ├── payment-api/                # Deployment, Service, HPA, PDB
│   │   ├── transaction-processor/      # Deployment, Service, HPA, PDB
│   │   ├── settlement-engine/          # Deployment, Service, HPA, PDB
│   │   ├── network-policies/           # PCI-DSS CDE ingress/egress network segmentation
│   │   └── configmaps-secrets/         # Region-aware ConfigMaps & CSI driver secrets
│   └── monitoring/                     # Observability configurations
│       ├── prometheus-alerts.yaml      # Multi-region replication and latency alerts
│       ├── grafana-dashboards/         # JSON dashboard models (DR Readiness, Incident, Exec)
│       └── cloudwatch-alarms.json      # AWS CloudWatch metric alarms definition
└── scripts/
    ├── failover/                       # Automated failover orchestration scripts
    │   ├── emergency-failover-orchestrator.py
    │   ├── initiate-aurora-failover.sh
    │   ├── trigger-dns-switchover.sh
    │   └── promote-elasticache-dr.sh
    ├── health-checks/                  # Deep health check probes & latency monitors
    │   ├── deep-health-check.py
    │   └── cross-region-latency-monitor.py
    └── dr-drill/                       # DR drill execution & chaos test harness
        ├── chaos-inject-node-drain.sh
        ├── simulate-route53-outage.py
        └── post-drill-scorecard.py
```

---

## 4. Architectural Recommendation Summary

- **Recommended Primary Architecture**: **Active-Passive (Hot Standby)** between **Mumbai (`ap-south-1`)** and **Hyderabad (`ap-south-2`)**.
- **Key Architectural Rationale**:
  1. **Financial Consistency & Split-Brain Elimination**: Financial payment aggregation requires strict ACID consistency. Multi-writer active-active across regions introduces distributed locking latencies and split-brain settlement discrepancies that risk double-crediting merchant accounts during intermittent network partitions.
  2. **Regulatory & Audit Alignment**: Single-writer Aurora Global Database in Mumbai replicating asynchronously to Hyderabad guarantees an RPO of `< 1 second` during normal operations, satisfying RBI Tier-1 requirements while maintaining absolute ledger audit integrity.
  3. **Realistic Team Operational Capacity**: PaySecure's platform engineering team consists of 8 engineers. An Active-Passive model with automated health checking and semi-automated failover keeps on-call burden sustainable and eliminates multi-region data conflict resolution operational overhead.
  4. **Cost Prudence**: Active-Passive delivers 99.99% availability and RTO of 3.5 minutes at 1.62x infrastructure spend (₹12.98 crore/yr), fitting within executive budget constraints, whereas Active-Active requires 2.05x spend (₹16.42 crore/yr).
  5. **Evolutionary Path**: The architecture is built with DynamoDB Global Tables and containerized stateless microservices on EKS, establishing a frictionless evolutionary path to active-active in Q4 2027 as daily volume scales to ₹1,500 crore.

---

## 5. Verification & Compliance Standards

- **RBI Master Direction on Payment and Settlement Systems (2024)** (Mandatory DR Site, RTO < 4 hrs, near-zero RPO).
- **RBI Directive on Storage of Payment System Data (DPSS.CO.OD No. 2785/06.08.005/2017-18)** (100% Indian Data Localisation).
- **PCI DSS v4.0** Requirements 1.3, 3.5.1, 4.2.1, 10.2, 12.10 (Cardholder Data Environment isolation, AES-256-GCM, TLS 1.3, annual & quarterly BCP drills).
- **NPCI UPI Procedural Guidelines & Technical Specifications** (End-to-end P99 < 300 ms, 99.95% network availability).
- **Information Technology Act, 2000 (Section 43A)** & **Digital Personal Data Protection Act, 2023 (DPDPA)** (Reasonable security safeguards and data residency).
---

<div align="center">

## 👨‍💻 Author

# Nihal N

### DevOps | Cloud | Kubernetes | AWS 

[![LinkedIn](https://img.shields.io/badge/LinkedIn-Nihal%20N-blue?logo=linkedin)](https://www.linkedin.com/in/nihal-n-cse/)

**If you found this repository useful, consider giving it a ⭐**

</div>

---
