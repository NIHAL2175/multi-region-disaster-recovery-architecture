# PaySecure Gateway: Data Sovereignty & Regulatory Compliance Matrix

**Document ID**: PSG-GRC-001  
**Target Legal & Regulatory Frameworks**:
1. Reserve Bank of India (RBI) Master Direction on Payment Systems (2024)
2. RBI Directive on Storage of Payment System Data (DPSS.CO.OD No. 2785/06.08.005/2017-18)
3. Payment Card Industry Data Security Standard (PCI DSS) v4.0
4. National Payments Corporation of India (NPCI) UPI Technical Standards
5. Information Technology Act, 2000 (Section 43A - Sensitive Personal Data)
6. Digital Personal Data Protection Act, 2023 (DPDPA)
7. SEBI Technology Risk Management Guidelines

---

## 1. Statutory Data Classification & Residency Policy

Under Indian financial regulations, all data processed by a payment aggregator is not homogenous. PaySecure classifies all digital assets into **six strict data categories**, each bound by specific residency constraints, encryption mandates, and cross-region replication scopes:

```
+-------------------------------------------------------------------------------------------------------------------------------+
| PaySecure Comprehensive Regulatory Data Classification Matrix                                                                 |
+----------------------+---------------------------+---------------------+-----------------------+------------------------------+
| Data Category        | Concrete Examples         | Statutory Residency | Authorized Scope      | Encryption & Security        |
|                      |                           | Mandate             | of DR Replication     | Standard Applied             |
+----------------------+---------------------------+---------------------+-----------------------+------------------------------+
| 1. Cardholder Data   | Primary Account Number    | 100% India Only     | Indian AWS Regions    | AES-256-GCM Envelope         |
|    (CHD / SAD)       | (PAN), Expiry, CVV (in-   | (RBI 2018 Directive | Exclusively (Mumbai   | Encryption; Multi-Region KMS |
|                      | memory only), Cardholder  | & PCI DSS Req 3.5)  | ap-south-1 & Hyd      | Keys; CDE Namespace Isolation|
|                      | Full Legal Name           |                     | ap-south-2). Zero intl| mTLS 1.3 in transit          |
+----------------------+---------------------------+---------------------+-----------------------+------------------------------+
| 2. Transaction Data  | Transaction IDs, Order    | 100% India Only     | Indian AWS Regions    | AES-256 at rest (Aurora DB); |
|    (Financial Ledger)| Amounts, Timestamps, UTR, | (RBI Master         | Exclusively (Storage  | TLS 1.3 across transit;      |
|                      | Customer VPA/UPI ID, Fees | Direction Section   | WAL replication < 1s  | HMAC-SHA256 non-repudiation  |
|                      | & Net Settlement Batches  | 34 & PSS Act 2007)  | across Mumbai & Hyd)  | transaction signing          |
+----------------------+---------------------------+---------------------+-----------------------+------------------------------+
| 3. Merchant Profile  | Merchant Business Legal   | 100% India Only     | Indian AWS Regions    | AES-256 database encryption; |
|    & Banking Data    | Name, Bank Nodal Account, | (RBI Master         | Exclusively (Aurora   | Field-level encryption for   |
|                      | IFSC Code, Authorized     | Direction on        | Global DB & DynamoDB  | IFSC and account numbers via |
|                      | Signatory Aadhaar/PAN     | Payment Aggregators)| Global Tables)        | Dedicated KMS CMK            |
+----------------------+---------------------------+---------------------+-----------------------+------------------------------+
| 4. Operational &     | Infrastructure Logs,      | India Preferred;    | Primary: Mumbai & Hyd;| PII & Cardholder Data strictly|
|    Telemetry Logs    | Distributed Traces, CPU/  | Operational copies  | Secondary (Optional): | redacted at ingestion; S3    |
|                      | Memory Metrics, Synthetic | permitted in SG if  | CloudWatch cross-     | Object Lock in Compliance    |
|                      | Health Probe Results      | PII is redacted     | region monitoring     | Mode for 7-year audit logs   |
+----------------------+---------------------------+---------------------+-----------------------+------------------------------+
| 5. Configuration &   | Route 53 Health Checks,   | No Statutory        | Replicated across all | Encrypted in transit; zero   |
|    Routing Metadata  | Rate Limiting Rules,      | Residency Constraint| regional management   | PII; strict IAM least-       |
|                      | Feature Flags, Kubernetes | (Stateless config)  | control planes        | privilege RBAC               |
|                      | Deployment Manifests      |                     | (GitOps / Terraform)  |                              |
+----------------------+---------------------------+---------------------+-----------------------+------------------------------+
| 6. Anonymized Trend  | Aggregated hourly TPS,    | No Statutory        | Replicated to multi-  | Irreversible k-anonymity     |
|    & Analytics Data  | payment rail share %,     | Constraint (Provided| region analytic stores| hashing (differential        |
|                      | macro success rates       | irreversible anonym)| (Athena / Redshift)   | privacy verified by DPO)     |
+----------------------+---------------------------+---------------------+-----------------------+------------------------------+
```

---

## 2. Regulatory Clause-by-Clause Architecture Mapping

### 2.1 RBI Master Direction on Payment and Settlement Systems (2024)
- **Clause 34.1: Mandatory Disaster Recovery Setup**:
  - *Requirement*: All authorized Payment Aggregators must establish a geographically separated Disaster Recovery (DR) site situated in a different seismic zone.
  - *PaySecure Architectural Implementation*: Primary region deployed in Mumbai (`ap-south-1`, Seismic Zone III); secondary DR region deployed in Hyderabad (`ap-south-2`, Seismic Zone II), separated by 710 km.
- **Clause 34.4: Recovery Time Objective (RTO) & Recovery Point Objective (RPO)**:
  - *Requirement*: RTO shall not exceed 4 hours for critical payment systems; RPO shall be near-zero for committed financial ledger entries.
  - *PaySecure Implementation*: Hot Standby architecture delivers **verified RTO = 3.5 minutes** (vastly superior to the 4-hour statutory ceiling) and **RPO < 1.0 second** via storage-level Aurora replication.
- **Clause 36.2: Regular BCP Drills**:
  - *Requirement*: Multi-region disaster recovery drills must be conducted at least twice annually with formal reporting to the Board.
  - *PaySecure Implementation*: Annual DR Drill Plan schedules **4 quarterly full-failover drills** and **12 monthly component drills**.

---

### 2.2 RBI Directive on Storage of Payment System Data (DPSS 2018 / 2023 Updates)
- *The Statutory Directive*:
  > *"All system providers shall ensure that the entire data relating to payment systems operated by them are stored in a system only in India. This data should include Full End-to-End transaction details, information collected / carried / processed as part of the message / payment instruction."*
- *Foreign Processing Conditions*:
  Under the RBI FAQs dated June 26, 2019, if processing is conducted abroad, the data must be transferred back to India for storage within 24 hours, and **all foreign copies must be permanently purged**.
- *PaySecure Strict Architectural Safeguard*:
  PaySecure completely rejects overseas replication (such as AWS Singapore or Frankfurt) for transactional or card data. By maintaining primary storage in Mumbai and secondary replication in Hyderabad, **100% of payment data remains perpetually on Indian sovereign territory**, guaranteeing zero regulatory exposure.

---

### 2.3 PCI DSS v4.0 Compliance Mapping
- **Requirement 1.3: Network Segmentation & CDE Boundary**:
  - *Implementation*: Cardholder Data Environment (CDE) is quarantined in dedicated Kubernetes namespace `paysecure-cde`. Kubernetes `NetworkPolicy` blocks all incoming traffic except authorized mTLS connections on port 8443 from `payment-api`.
- **Requirement 3.5.1: Strong Cryptography for Stored Cardholder Data**:
  - *Implementation*: Primary Account Numbers (PANs) are tokenized immediately in memory. Card vaults in Aurora use AES-256 envelope encryption backed by AWS KMS Multi-Region Customer Managed Keys (`mrk-cde-mumbai-master` and `mrk-cde-hyd-replica`).
- **Requirement 4.2.1: Transmission Security over Public Networks**:
  - *Implementation*: Ingress ALBs and internal service meshes strictly enforce TLS 1.3 with forward secrecy (`ECDHE-RSA-AES256-GCM-SHA384`).
- **Requirement 10.2: Automated Audit Logging**:
  - *Implementation*: Every decryption invocation and administrative change is logged to Amazon S3 with AWS Object Lock in Compliance Mode for a tamper-proof 7-year retention.
- **Requirement 12.10.2: Incident Response & BCP Testing**:
  - *Implementation*: 12 production disaster recovery runbooks covering regional loss, key compromise, and database corruption are rehearsed quarterly.

---

### 2.4 NPCI UPI Technical Specifications
- **End-to-End Latency Requirement**: Total processing turnaround from UPI request to response must remain strictly **under 300 ms (P99)**.
  - *PaySecure Implementation*: Cross-region asynchronous replication adds 0 ms to the local commit path. P99 latency in Mumbai is 180 ms; during failover in Hyderabad, P99 latency is 205 ms (leaving a 95 ms safety margin below NPCI's 300 ms ceiling).
- **System Availability SLA**: 99.95% minimum uptime for UPI participant systems.
  - *PaySecure Implementation*: Architecture targets **99.99% service availability** (< 52.6 min annual downtime), exceeding NPCI standards.

---

### 2.5 Information Technology Act, 2000 (Section 43A) & DPDP Act 2023
- **Section 43A IT Act (Reasonable Security Practices)**:
  - Establishes corporate liability for negligence in protecting Sensitive Personal Data or Information (SPDI).
  - *PaySecure Implementation*: ISO 27001, SOC 2 Type II, and multi-region automated replication provide statutory proof of "reasonable security practices and procedures".
- **Digital Personal Data Protection Act, 2023 (DPDPA)**:
  - Section 8 mandates technical safeguards against personal data breaches.
  - Section 16 governs cross-border transfers. PaySecure avoids cross-border transfer entirely by anchoring all data replication domestically within Mumbai and Hyderabad.
