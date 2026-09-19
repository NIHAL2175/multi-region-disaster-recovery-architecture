# PaySecure DR Runbook: RB-03 DNS Poisoning / DNS Infrastructure Failure

## 1. Scenario Identification
- **Runbook ID**: RB-03
- **Scenario Name**: DNS Poisoning, Route 53 Control Plane Outage, or Malicious Cache Injection
- **Category**: Security / Global Network Infrastructure
- **Severity Classification**: P1 - High Security Emergency
- **Target RTO**: < 5 Minutes
- **Target RPO**: Zero Data Loss (RPO = 0)
- **Affected Components**: Domain `api.paysecure.in`, AWS Route 53 Hosted Zone `Z1234567890`, DNSSEC validation chains, Public Anycast Ingress.
- **Incident Commander Role**: Principal Security Architect / CISO
- **Secondary Roles**: Lead Network Engineer, CloudFront / CDN Administrator, Merchant Support Lead

---

## 2. Detection Mechanism
1. **DNSSEC Validation Failure Alert**: `DNSSECChainValidationFailed`
   - Synthetic probe from 12 global points detects DNSSEC `BOGUS` signature response.
2. **Unexpected IP Resolution Alert**: `Route53UnexpectedResolutionTarget`
   - CloudWatch / ThousandEyes alert: `api.paysecure.in` resolves to an IP outside PaySecure's assigned ALB / Global Accelerator CIDR blocks.
3. **Customer SSL Certificate Mismatch Reports**: Spike in client TLS handshake termination errors (`ERR_CERT_COMMON_NAME_INVALID`).

---

## 3. Impact Assessment
- **Security Exposure**: Man-in-the-Middle (MitM) risk; potential interception of merchant API keys and cardholder payload tokens if attackers spoof TLS certificates.
- **Traffic Disruption**: Up to 60% of client requests blackholed or rejected due to TLS certificate errors.
- **Regulatory Liability**: Mandatory CERT-In notification within 6 hours under the Indian Cyber Security Directions (2022).

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge Security Incident | Security Lead | `pd incident ack -i $INCIDENT_ID` | Security War Room established |
| **2** | Confirm DNSSEC Validation Status | Network Eng | `dig +dnssec +trace api.paysecure.in @8.8.8.8` | Inspects RRSIG and DS records for tampering |
| **3** | Lock Route 53 IAM Permissions | Security Lead | `aws iam attach-role-policy --role-name SRE-Operator-Role --policy-arn arn:aws:iam::aws:policy/AWSDenyAllRoute53Modifications` | Prevents unauthorized modification of hosted zones |
| **4** | Activate Out-of-Band Direct Anycast Ingress | Network Eng | Trigger AWS Global Accelerator bypass: routes traffic directly to static IP `13.248.xxx.yyy` | Enterprise merchants directed to Anycast IPs |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Inspect Route 53 Audit Trail in CloudTrail | Security Lead | `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=ChangeResourceRecordSets --max-results 10` | Identifies rogue API keys or unauthorized DNS record changes |
| **6** | Check Registrar Name Server Delegation | Network Eng | `whois paysecure.in | grep -i "Name Server"` | Validates that registry-level delegation to AWS name servers is intact |
| **7** | Query Global Resolvers for Propagation | Network Eng | `for ns in 1.1.1.1 8.8.8.8 9.9.9.9; do dig +short api.paysecure.in @$ns; done` | Identifies scope of poisoned DNS cache |

---

## 6. Failover & Remediation Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **8** | **DECISION BRANCH 1**: AWS Compromise vs External ISP Poisoning | Security Lead | *If Route 53 hosted zone modified -> Revert records & rotate credentials. If external ISP cache poisoned -> Deploy secondary DNS provider (Cloudflare).* | Determined: Route 53 record modified by rogue credentials |
| **9** | Revert Route 53 Records to Known Good State | Network Eng | `aws route53 change-resource-record-sets --hosted-zone-id Z1234567890 --change-batch file://configs/route53-golden-backup.json` | Authorized ALB endpoints restored in Route 53 |
| **10** | Invalidate Cloudflare / Google DNS Cache | Network Eng | Invoke Google Flush Cache API: `curl -X POST "https://dns.google/resolve?name=api.paysecure.in&type=A&flush=true"` | Clears poisoned entries from Google Public DNS immediately |
| **11** | Rotate AWS Route 53 Administrative Credentials | Security Lead | `aws iam delete-access-key --user-name route53-admin-user --access-key-id $COMPROMISED_KEY` | Compromised vector neutralized |
| **12** | Enforce DNSSEC Re-signing | Network Eng | `aws route53 enable-hosted-zone-dnssec --hosted-zone-id Z1234567890` | Cryptographic signature re-established across all RRs |
| **13** | Broadcast Static Endpoint to Critical Merchants | Merchant Lead | Dispatch P1 advisory directing top merchants to secondary domain `api-backup.paysecure.in` | Top 20 merchants resume processing |
| **14** | Verify Clean DNS Resolution Across All Telecoms | Network Eng | Test probes against Airtel, Jio, Vodafone-Idea DNS: `python scripts/health-checks/verify-dns-telecoms.py` | 100% resolvers return verified PaySecure ALB IPs |

---

## 7. Communication Protocol
- **Regulatory Template**: Mandatory filing submitted to `incident@cert-in.org.in` within 6 hours.
- **Merchant Advisory**: Inform merchants that DNS integrity validation succeeded with zero credential compromise.

---

## 8. Verification & Validation
- Validate TLS certificate trust chain: `openssl s_client -connect api.paysecure.in:443 -servername api.paysecure.in < /dev/null | grep -i "Verify return code"` -> Must return `0 (ok)`.

---

## 9. Rollback Procedure
If secondary DNS delegation causes resolution failures:
1. Re-delegate primary NS records to AWS Route 53 authoritative name servers (`ns-xxx.awsdns.com`).
2. Verify registry WHOIS status.

---

## 10. Post-Incident Review Checklist
- [ ] Enforce Multi-Factor Authentication (MFA) on AWS Route 53 administrative API actions.
- [ ] Activate AWS Route 53 Resolver DNS Firewall with threat intelligence feeds.
- [ ] Submit final forensic incident report to CERT-In and RBI.
