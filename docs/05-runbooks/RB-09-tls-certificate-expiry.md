# PaySecure DR Runbook: RB-09 Certificate Expiry / TLS Failure

## 1. Scenario Identification
- **Runbook ID**: RB-09
- **Scenario Name**: TLS/SSL Certificate Expiration or Cipher Suite Misconfiguration on `api.paysecure.in`
- **Category**: Infrastructure / Cryptographic Identity
- **Severity Classification**: P1 - Ingress Blackout
- **Target RTO**: < 5 Minutes (Emergency Certificate Re-binding < 3 Minutes)
- **Target RPO**: Zero Transaction Loss (RPO = 0)
- **Affected Components**: Application Load Balancers, Route 53, AWS Certificate Manager (ACM), EKS Ingress Controllers.
- **Incident Commander Role**: Principal Security Engineer / Cloud SRE
- **Secondary Roles**: Network Engineer, Merchant Technical Support Lead

---

## 2. Detection Mechanism
1. **Certificate Expiration Monitoring Alarm**: `TLSCertificateExpiryCritical`
   - Synthetic Probe: `probe_ssl_earliest_cert_expiry{job="blackbox_tls"} - time() < 86400` (< 24 hours to expiration).
2. **Client TLS Handshake Failure Spike**: `ALBClientTLSNegotiationErrorHigh`
   - Metric: `AWS/ApplicationELB -> ClientTLSNegotiationErrorCount > 100` errors/min.
3. **Synthetic Handshake Probe Failure**: `SyntheticTLSHandshakeFailed`
   - Prometheus Alert: `probe_http_ssl{instance="https://api.paysecure.in"} == 0`.

---

## 3. Impact Assessment
- **Client Handshake Termination**: All mobile merchant SDKs and web browsers terminate HTTPS connections immediately with `SEC_ERROR_EXPIRED_CERTIFICATE` or `ERR_CERT_DATE_INVALID`.
- **Transaction Drop**: 100% of incoming requests fail before reaching application pods.
- **Reputational Damage**: Immediate merchant alarm regarding gateway security posture.

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge TLS P1 Alert | Security SRE | `pd incident ack -i $TLS_INCIDENT_ID` | Incident triage initiated |
| **2** | Inspect Active Certificate on Domain | Network Eng | `echo | openssl s_client -servername api.paysecure.in -connect api.paysecure.in:443 2>/dev/null | openssl x509 -noout -dates -issuer` | Confirms exact expiration timestamp or invalid intermediate chain |
| **3** | Check Backup Pre-Provisioned ACM Certificate | Security SRE | `aws acm list-certificates --region ap-south-1 --certificate-statuses ISSUED --query 'CertificateSummaryList[?DomainName==\`api.paysecure.in\`]'` | Identifies pre-issued wildcard certificate ARN |
| **4** | Activate Standby Hyderabad Ingress (Zero-Downtime Shift) | Network Eng | Invert Route 53 Primary health status to steer traffic to Hyderabad (which holds a valid separate ACM cert) | Global DNS begins routing to Hyderabad in 30 seconds |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Verify Hyderabad TLS Certificate Validity | Network Eng | `echo | openssl s_client -servername api-hyd.paysecure.in -connect api-hyd.paysecure.in:443 2>/dev/null | openssl x509 -noout -dates` | Confirms Hyderabad certificate valid for next 180 days |
| **6** | Inspect ACM Auto-Renewal Log in CloudTrail | Security SRE | `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventSource,AttributeValue=acm.amazonaws.com` | Identifies why automated DNS validation renewal stalled |

---

## 6. Emergency Certificate Binding Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **7** | Request Emergency ACM Public Certificate | Security SRE | `aws acm request-certificate --domain-name api.paysecure.in --validation-method DNS --idempotency-token emergencypaysecure2026` | Generates new certificate ARN in `PENDING_VALIDATION` |
| **8** | Inject DNS Validation CNAME into Route 53 | Network Eng | `python scripts/failover/auto-validate-acm-dns.py --cert-arn $NEW_CERT_ARN` | Injects required CNAME; validation succeeds within 60s |
| **9** | Wait for Certificate Issuance | Security SRE | `aws acm wait certificate-validated --certificate-arn $NEW_CERT_ARN` | Status transitions to `ISSUED` |
| **10** | Bind New Certificate to Mumbai ALB HTTPS Listener | Security SRE | `aws elbv2 modify-listener --listener-arn $MUM_ALB_HTTPS_LISTENER_ARN --certificates CertificateArn=$NEW_CERT_ARN` | ALB applies new certificate with zero connection resets |
| **11** | Verify Local HTTPS Handshake in Mumbai | Network Eng | `curl -Iv --resolve api.paysecure.in:443:$MUM_ALB_IP https://api.paysecure.in/health/ready` | Handshake succeeds: `HTTP/2 200`, certificate verified clean |
| **12** | Revert Route 53 DNS Traffic to Mumbai | Network Eng | `aws route53 update-health-check --health-check-id hc-mumbai-deep-primary --no-inverted` | Traffic returns to primary Mumbai region |

---

## 7. Communication Protocol
- **Engineering Comms**: `[P1 RESOLVED] Expired TLS certificate replaced with newly issued ACM cert. Traffic shifted back to Mumbai.`
- **Merchant Notice**: `PaySecure has concluded a routine cryptographic certificate rotation. Gateway connectivity is fully normal.`

---

## 8. Verification & Validation
- Check SSL Labs probe: `ssllabs-scan api.paysecure.in` -> Grade must be `A+`.
- Confirm cipher suites enforce `TLS_AES_256_GCM_SHA384` and `TLS_CHACHA20_POLY1305_SHA256`.

---

## 9. Rollback Procedure
If new certificate causes compatibility issues with legacy merchant POS terminals:
1. Re-bind pre-provisioned DigiCert wildcard certificate.
2. Maintain TLS 1.2 backwards-compatibility cipher policy `ELBSecurityPolicy-TLS13-1-2-2021-06`.

---

## 10. Post-Incident Review Checklist
- [ ] Configure AWS Config rule `acm-certificate-expiration-check` with 30-day, 14-day, 7-day, and 1-day alerts.
- [ ] Implement automated weekly synthetic certificate audit in DR drill plan.
