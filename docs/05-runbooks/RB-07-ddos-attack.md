# PaySecure DR Runbook: RB-07 DDoS Attack on Payment API

## 1. Scenario Identification
- **Runbook ID**: RB-07
- **Scenario Name**: Distributed Denial of Service (DDoS) Attack Surge (1,200 TPS to 150,000+ RPS)
- **Category**: Security / External Volumetric Attack
- **Severity Classification**: P1 - High Operational Security Incident
- **Target RTO**: Attack Mitigation < 3 Minutes; Service Stabilization < 5 Minutes
- **Target RPO**: Zero Transaction Loss (RPO = 0)
- **Affected Components**: Internet-facing Application Load Balancers, AWS WAFv2, CloudFront, Route 53 Edge, EKS Ingress Pods.
- **Incident Commander Role**: Principal Security Architect / SRE Lead
- **Secondary Roles**: AWS Shield Response Team (SRT) Liaison, Network Engineer, Merchant Relations Lead

---

## 2. Detection Mechanism
1. **ALB Request Volume Surge Alert**: `ALBRequestRateSurgeSevere`
   - Metric: `AWS/ApplicationELB -> RequestCountPerTarget > 150000 req/sec` (125x above peak baseline).
2. **AWS Shield Advanced DDoS Detection Alert**: `ShieldDDoSAttackDetected`
   - Event: `AWS/DDoSProtection -> AttackDetected == 1` on ALB ARN.
3. **Backend Target Connection Latency Spike**: `TargetResponseTimeHigh`
   - Metric: `TargetResponseTime > 1500 ms` with 5xx error rate climbing above 5%.

---

## 3. Impact Assessment
- **System Resource Starvation**: Legitimate merchant API calls dropped or timed out; ALB target groups saturated.
- **Financial Risk**: Merchant transaction drops during attack translate to ₹37.5 Lakh INR/hour revenue loss.
- **Infrastructure Cost**: Volumetric data transfer overage if attack traffic reaches backend EKS nodes.

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge DDoS P1 Alert | Security Lead | `pd incident ack -i $DDoS_INCIDENT_ID` | SIRT War Room convened |
| **2** | Activate AWS Shield Response Team (SRT) Engagement | Security Lead | `aws shield associate-drt-role --role-arn arn:aws:iam::123456789012:role/AWSShieldDRTRole` | Grants AWS DDoS Response Team 24/7 proactive mitigation access |
| **3** | Engage AWS Shield Automatic Layer 7 Mitigation | Security Lead | `aws shield update-application-layer-automatic-mitigation --resource-arn $ALB_ARN --action BLOCK` | Shield begins automatically blocking Layer 7 HTTP flood signatures |
| **4** | Activate Aggressive Rate-Limiting WAF Rule | Security Lead | `aws wafv2 update-web-acl --name paysecure-prod-waf --scope REGIONAL --id $WAF_ID --default-action Block="{}" --rules file://configs/waf-emergency-ddos-rules.json --lock-token $WAF_TOKEN` | Enforces rate limit of 100 requests / 5 minutes per IP |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Analyze Attack Vector via CloudWatch Logs Insights | Security Lead | Query WAF logs: `fields httpRequest.clientIp, httpRequest.uri, httpRequest.country | stats count() by httpRequest.clientIp, httpRequest.country | sort count desc | limit 20` | Identifies botnet origin countries (e.g., Eastern Europe / Botnet ASN) |
| **6** | Check Legitimate Merchant API Traffic Whitelist | Lead SRE | Verify top 100 merchant IP ranges in WAF IPSet `paysecure-merchant-whitelist` | Whitelisted merchant IPs bypass WAF blocks |
| **7** | Monitor ALB Target Group Healthy Host Count | Lead SRE | `aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[*].TargetHealth.State'` | Confirms whether EKS pods remain healthy |

---

## 6. Failover & Traffic Engineering Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **8** | **DECISION BRANCH 1**: Absorb via WAF vs Global DNS Anycast Shedding | Security Lead | *If attack volume < 200 Gbps -> Filter at WAF/Shield. If attack saturates AWS Transit Gateway -> Split traffic across Hyderabad and AWS CloudFront.* | WAF rule + Geo-Blocking applied |
| **9** | Enforce Geographic Rate Fencing (India-Only Ingress) | Security Lead | `aws wafv2 update-ip-set --name paysecure-geo-fence --scope REGIONAL --id $GEO_IP_SET_ID ...` | Blocks all non-Indian IP traffic on payment API endpoints |
| **10** | Scale Ingress Microservice Pods | Lead SRE | `kubectl -n paysecure scale deployment payment-api --replicas=60` | EKS scales to absorb legitimate merchant re-tries |
| **11** | Enable CloudFront Ingress Scrubbing Tier | Network Eng | Route DNS `api.paysecure.in` to Amazon CloudFront with AWS Edge DDoS Scrubbing | Traffic scrubbed at 450+ global AWS Points of Presence |
| **12** | Verify Legitimate Merchant Transaction Success | Lead SRE | `curl -Iv https://api.paysecure.in/health/ready` | Returns `HTTP 200 OK`; legitimate transactions passing |

---

## 7. Communication Protocol
- **Merchant Advisory**: `PaySecure network security systems are actively scrubbing a volumetric DDoS event. Legitimate transactions are authorized normally.`
- **CERT-In Report**: Formally submitted within 6 hours under Rule 12.

---

## 8. Verification & Validation
- Check WAF Block rate: `sum(rate(aws_wafv2_blocked_requests_total[1m])) > 120000 req/sec`.
- Confirm Payment API success rate: `sum(rate(http_requests_total{status="200"}[1m])) / sum(rate(http_requests_total[1m])) >= 0.995`.

---

## 9. Rollback Procedure
Once attack ceases:
1. Deactivate emergency geo-blocking rules in WAF.
2. Revert `payment-api` replica count to standard autoscaling baseline (18 pods).

---

## 10. Post-Incident Review Checklist
- [ ] Submit WAF rule efficacy report to AWS Shield Response Team.
- [ ] Conduct forensic log export and submit IP indicators of compromise (IoCs) to CERT-In.
- [ ] Review AWS Shield Advanced Cost Protection credit request for scaling charges incurred during attack.
