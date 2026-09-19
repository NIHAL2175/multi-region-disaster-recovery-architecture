# PaySecure DR Runbook: RB-11 Ransomware Attack on Infrastructure

## 1. Scenario Identification
- **Runbook ID**: RB-11
- **Scenario Name**: Ransomware Infection & Host File System Encryption across EKS Nodes and CI/CD Pipeline
- **Category**: Security / Host Compromise & Malware
- **Severity Classification**: P1 - Catastrophic Security Emergency
- **Target RTO**: Infrastructure Rebuild < 30 Minutes; Clean Restoration < 45 Minutes
- **Target RPO**: < 15 Minutes (Restoration from Immutable S3 Backups)
- **Affected Components**: EKS Worker Nodes in Mumbai, Jenkins/GitHub Actions CI/CD Runners, ECR Container Registries, and Local Persistent Volumes.
- **Incident Commander Role**: Chief Information Security Officer (CISO)
- **Secondary Roles**: Lead Forensic SRE, Lead DBA, External Cyber Incident Response Firm

---

## 2. Detection Mechanism
1. **GuardDuty Host Malware Alert**: `Execution:EC2/MaliciousFile`
   - GuardDuty detects ransomware dropper / encrypted file patterns on worker nodes.
2. **Kubernetes Kubelet Disk Pressure Spike**: `KubeletDiskPressureHigh`
   - All nodes simultaneously exhaust disk IOPS due to mass background encryption.
3. **Ransom Note Ingestion in Log Aggregator**:
   - Alert fires on Elasticsearch query: `pattern: "RESTORE_YOUR_FILES_README.txt"`.

---

## 3. Impact Assessment
- **Compute Fleet Compromise**: Application containers crash; host operating systems locked.
- **Supply Chain Vulnerability**: CI/CD pipeline infected; production deployment keys potentially extracted.
- **Regulatory Mandate**: Mandatory CERT-In breach reporting within 6 hours; RBI Cyber Security Framework forensic audit protocol invoked.

---

## 4. Immediate Containment & Quarantining (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge Ransomware Emergency | CISO | Mobilize SIRT via Encrypted Mobile Bridge (Signal / Out-of-band) | Incident War Room open |
| **2** | Immediate Network Isolation of Mumbai VPC | Security SRE | `aws ec2 update-security-group-rule-descriptions-ingress --group-id $ALL_EKS_NODES_SG --security-group-rule-descriptions '{"SecurityGroupRuleId":"sgr-all","Description":"EMERGENCY_ISOLATE"}'` | Blocks all egress and ingress to infected EKS nodes |
| **3** | Revoke CI/CD Deployment IAM Access | Security SRE | `aws iam detach-role-policy --role-name CICD-Deployer-Role --policy-arn arn:aws:iam::aws:policy/AdministratorAccess` | Neutralizes pipeline lateral movement vector |
| **4** | Halt Route 53 Traffic to Mumbai | Network Eng | Force Route 53 to withdraw Mumbai ALB: `aws route53 change-resource-record-sets --hosted-zone-id Z1234567890 --change-batch file://configs/route53-isolate-mumbai.json` | Stops customers connecting to compromised environment |

---

## 5. Forensic Blast Radius Assessment (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Check Database Tier Integrity | Lead DBA | `aws rds describe-db-clusters --db-cluster-identifier paysecure-primary --query 'DBClusters[0].Status'` | Aurora is storage-isolated; verify database engine unaffected |
| **6** | Inspect S3 Compliance Bucket Object Lock | Security SRE | `aws s3api get-object-legal-hold --bucket paysecure-compliance-mumbai --key critical-audit.log` | Confirms AWS Object Lock Compliance Mode prevented encryption of logs |
| **7** | Inspect Secondary Region (`ap-south-2`) Status | Security SRE | `kubectl --context paysecure-hyd get nodes && aws guardduty list-findings --region ap-south-2` | **CONFIRMS HYDERABAD IS COMPLETELY UNINFECTED (Zero lateral spread)** |

---

## 6. Infrastructure Rebuild & Clean Recovery Procedure (5–30 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **8** | **DECISION BRANCH 1**: Cleanse Infected Nodes vs Complete Teardown | CISO | *Never attempt to decrypt or salvage infected nodes. Execute scorched-earth teardown and rebuild from verified immutable IaC in Hyderabad.* | Decision: Full Teardown in Mumbai; Failover to Hyderabad |
| **9** | Terminate Infected EKS Node Groups | Security SRE | `aws eks delete-nodegroup --cluster-name paysecure-mumbai-prod --nodegroup-name ng-app-tier` | Destroys all infected EC2 instances and encrypted EBS volumes |
| **10** | Detach and Promote Hyderabad Aurora Database | Lead DBA | `aws rds remove-from-global-cluster --region ap-south-2 --global-cluster-identifier paysecure-global --db-cluster-identifier arn:aws:rds:ap-south-2:123456789012:cluster:paysecure-secondary` | Hyderabad promoted as pristine standalone database |
| **11** | Verify Image Signatures in ECR (Cosign Validation) | Security SRE | `cosign verify --key file://configs/cosign.pub 123456789012.dkr.ecr.ap-south-2.amazonaws.com/paysecure/payment-api:latest` | Confirms container images in Hyderabad are cryptographically signed and un-tampered |
| **12** | Scale Up Clean Workloads in Hyderabad | Primary SRE | `kubectl --context paysecure-hyd -n paysecure scale deployment payment-api transaction-processor settlement-engine --replicas=24` | Workloads deployed cleanly from verified container images |
| **13** | Steer Global DNS Ingress to Hyderabad | Network Eng | `aws route53 change-resource-record-sets --hosted-zone-id Z1234567890 --change-batch file://configs/route53-promote-hyd.json` | 100% production traffic serviced by clean Hyderabad cluster |
| **14** | Provision Isolated Forensic Sandbox VPC | Forensic Lead | `terraform -chdir=configs/terraform/forensics init && terraform apply -auto-approve` | Spins up quarantined sandbox for evidence analysis |

---

## 7. Communication Protocol
- **CERT-In Mandatory Incident Filing**: Submitted within 6 hours with preliminary IoCs.
- **RBI Cyber Security Framework Escalation**: Formal report to RBI Cyber Security Cell.
- **Law Enforcement Report**: Formal complaint lodged with State Cyber Crime Police Station.

---

## 8. Verification & Validation
- Validate zero lateral movement in Hyderabad: GuardDuty findings count = 0.
- Execute synthetic payment test: `curl https://api.paysecure.in/health/deep` -> Returns `200 OK`.

---

## 9. Rollback Procedure
*Ransomware scenarios have NO rollback to infected environments. Recovery proceeds forward exclusively on rebuilt infrastructure.*

---

## 10. Post-Incident Review Checklist
- [ ] Enforce read-only root filesystems on all Kubernetes container pods.
- [ ] Implement Amazon GuardDuty Runtime Monitoring with automated agent quarantine.
- [ ] Mandate ephemeral, signed GitOps deployments with short-lived STS tokens.
