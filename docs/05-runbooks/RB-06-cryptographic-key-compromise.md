# PaySecure DR Runbook: RB-06 Cryptographic Key Compromise

## 1. Scenario Identification
- **Runbook ID**: RB-06
- **Scenario Name**: Compromise of AWS KMS Cardholder Data Encryption Key (`mrk-cde-mumbai-master`)
- **Category**: Security / Cryptographic Emergency
- **Severity Classification**: P1 - Critical Security Breach
- **Target RTO**: Key Containment < 10 Minutes; Emergency Rotation & Re-encryption < 4 Hours
- **Target RPO**: Zero Data Loss (RPO = 0)
- **Affected Components**: AWS KMS Multi-Region Key (`mrk-cde-mumbai-master` and replica `mrk-cde-hyd-replica`), `tokenisation-service`, card vault database tables in Aurora, and PCI-DSS CDE scope.
- **Incident Commander Role**: Chief Information Security Officer (CISO)
- **Secondary Roles**: Lead Cryptographic Engineer, Lead DBA, Legal Counsel, Card Network Liaison

---

## 2. Detection Mechanism
1. **GuardDuty KMS Anomaly Alert**: `KMSAnomalousAccessDetected`
   - GuardDuty Finding: `UnauthorizedAccess:IAMUser/KMSAnomaly` (Access from unauthorized IP / unexpected high volume of `kms:Decrypt` calls).
2. **KMS API Call Rate Spike**: `KMSDecryptVolumeSpikeHigh`
   - CloudWatch Alarm: `kms:Decrypt` requests exceed 3x standard hourly baseline.
3. **Internal Security Audit / Whistleblower Report**: Forensic evidence of leaked administrative IAM credentials with KMS decryption privileges.

---

## 3. Impact Assessment
- **PCI-DSS Compliance Breach**: Loss of PCI-DSS Level 1 certification if uncontained, halting all credit/debit card processing privileges.
- **Mandatory Notification**: PCI-DSS Requirement 12.10 mandates incident notification to Card Networks (Visa, Mastercard, RuPay) and Acquiring Banks within 72 hours.
- **Cardholder Data Exposure**: Potential exposure of tokenized Primary Account Numbers (PANs).

---

## 4. Immediate Containment (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge Cryptographic Breach Alert | CISO | Mobilize Security Incident Response Team (SIRT) via Out-of-band PagerDuty | SIRT War Room opened |
| **2** | Revoke Compromised IAM User / Role Sessions | Security Lead | `aws iam put-user-policy --user-name compromised-admin --policy-name DenyAll --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*"}]}'` | Rogue credentials instantly disabled |
| **3** | Revoke Active STS Temporary Credentials | Security Lead | `aws iam put-role-policy --role-name SRE-Admin-Role --policy-name RevokeOldSessions --policy-document "{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*","Condition":{"DateLessThan":{"aws:TokenIssueTime":"$(date -u +%FT%TZ)"}}}]}"` | Terminates all in-flight compromised sessions |
| **4** | Restrict Compromised KMS Key Access Policy | Crypto Eng | `aws kms put-key-policy --key-id mrk-cde-mumbai-master --policy-name default --policy file://configs/kms-emergency-lockdown-policy.json` | Blocks all `kms:Decrypt` actions except authorized tokenisation pods |

---

## 5. Forensic Diagnostics (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Query CloudTrail for Decrypted Key Identifiers | Security Lead | `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=Decrypt --start-time $(date -u -d '2 hours ago' +%FT%TZ)` | Identifies total decrypted card records and caller IP |
| **6** | Audit Tokenisation Service Pod Logs | Primary SRE | `kubectl -n paysecure-cde logs -l app=tokenisation-service --since=2h | grep -i "decrypt"` | Confirms whether breach originated inside or outside CDE |
| **7** | Isolate CDE Kubernetes Namespace | Primary SRE | `kubectl patch networkpolicy cde-isolation -n paysecure-cde --type merge -p '{"spec":{"ingress":[]}}'` | Shuts down network access to tokenisation service |

---

## 6. Emergency Key Rotation & Re-Encryption Procedure (5–30 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **8** | Provision Pristine Replacement Multi-Region Key | Crypto Eng | `aws kms create-key --description "PaySecure CDE Master Key v2" --key-spec SYMMETRIC_DEFAULT --key-usage ENCRYPT_DECRYPT --multi-region --tags TagKey=PCI-DSS,TagValue=CDE-Production` | Generates clean multi-region key `mrk-cde-mumbai-v2` |
| **9** | Replicate Clean Key to Hyderabad | Crypto Eng | `aws kms replicate-key --key-id $NEW_KEY_MUM_ARN --replica-region ap-south-2 --description "PaySecure CDE Hyderabad Replica Key v2"` | Clean key replicated to `ap-south-2` |
| **10** | Update Kubernetes Secrets with New Key ARN | Primary SRE | `kubectl -n paysecure-cde set env deployment/tokenisation-service KMS_KEY_ARN_NEW=$NEW_KEY_MUM_ARN` | Tokenisation service armed with new encryption key |
| **11** | Execute In-Place Token Re-Encryption Job | Lead DBA | Run `scripts/failover/reencrypt-cardholder-tokens.py --old-key $OLD_KEY_ARN --new-key $NEW_KEY_MUM_ARN --batch-size 500` | Decrypts data keys with old key and immediately re-encrypts with v2 key |
| **12** | Verify 100% Records Re-Encrypted | Lead DBA | `SELECT count(*) FROM card_tokens WHERE kms_key_version != 'v2';` | Returns `0` (100% card tokens re-keyed) |
| **13** | Disable Compromised Master Key | Crypto Eng | `aws kms disable-key --key-id mrk-cde-mumbai-master` | Compromised key fully disabled in Mumbai |
| **14** | Disable Compromised Replica Key in Hyderabad | Crypto Eng | `aws kms disable-key --region ap-south-2 --key-id mrk-cde-hyd-replica` | Compromised key fully disabled in Hyderabad |
| **15** | Restore CDE NetworkPolicy Traffic | Primary SRE | `kubectl apply -f configs/kubernetes/network-policies/cde-isolation.yaml` | Restores mTLS traffic from `payment-api` |
| **16** | Restart Tokenisation Service Pods | Primary SRE | `kubectl -n paysecure-cde rollout restart deployment tokenisation-service` | Service online using exclusively v2 keys |

---

## 7. Communication Protocol
- **Card Networks Notification (Visa, Mastercard, RuPay)**: Formal declaration of security incident submitted within mandatory 72-hour window.
- **CERT-In Cyber Incident Report**: Mandatory notification filed under Rule 12 within 6 hours.
- **RBI Compliance Notice**: Briefing submitted to RBI Department of Payment and Settlement Systems.

---

## 8. Verification & Validation
- Execute test card tokenization and de-tokenization: `curl -s -k https://tokenisation-service.paysecure-cde:8443/test-crypto` -> Returns `200 OK (Key: v2)`.
- Confirm old key status: `aws kms describe-key --key-id $OLD_KEY_ARN --query 'KeyMetadata.KeyState'` -> Returns `Disabled`.

---

## 9. Rollback Procedure
*Note: Cryptographic rollbacks must NEVER re-enable compromised keys. If new key configuration fails, deploy secondary pristine key `mrk-cde-mumbai-v3`.*

---

## 10. Post-Incident Review Checklist
- [ ] Engage Qualified Security Assessor (QSA) for mandatory post-incident PCI-DSS audit.
- [ ] Mandate hardware security keys (FIDO2 / YubiKey) for all IAM users with KMS permissions.
- [ ] Conduct external penetration test of CDE isolation boundaries.
