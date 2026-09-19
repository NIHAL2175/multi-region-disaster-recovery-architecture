#!/usr/bin/env bash
set -euo pipefail

# PaySecure Gateway - Route 53 Manual Override Switchover
HOSTED_ZONE_ID="Z1234567890"
HYD_ALB_DNS="paysecure-hyd-alb-987654321.ap-south-2.elb.amazonaws.com"
HYD_ALB_ZONE="Z2111111"

echo "=== [$(date -u)] Updating Route 53 A-Record for api.paysecure.in ==="
CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Manual failover override to Hyderabad ALB",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.paysecure.in",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${HYD_ALB_ZONE}",
          "DNSName": "${HYD_ALB_DNS}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF
)

CHANGE_ID=$(aws route53 change-resource-record-sets   --hosted-zone-id "${HOSTED_ZONE_ID}"   --change-batch "${CHANGE_BATCH}"   --query 'ChangeInfo.Id'   --output text)

echo "=== [$(date -u)] Waiting for Route 53 DNS Sync (${CHANGE_ID}) ==="
aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}"

echo "=== [$(date -u)] DNS Propagation Verified ==="
dig @8.8.8.8 api.paysecure.in +short
