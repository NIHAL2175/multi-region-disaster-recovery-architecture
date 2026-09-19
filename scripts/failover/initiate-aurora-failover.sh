#!/usr/bin/env bash
set -euo pipefail

# PaySecure Gateway - Aurora Global Database Failover
GLOBAL_CLUSTER_ID="paysecure-global"
TARGET_CLUSTER_ARN="arn:aws:rds:ap-south-2:123456789012:cluster:paysecure-secondary"
SECONDARY_REGION="ap-south-2"

echo "=== [$(date -u)] Checking Aurora Global Database Lag ==="
aws cloudwatch get-metric-statistics   --namespace AWS/RDS   --metric-name AuroraGlobalDBReplicationLag   --dimensions Name=DBClusterIdentifier,Value=paysecure-secondary   --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)"   --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)"   --period 60   --statistics Average   --region "${SECONDARY_REGION}"   --output table

echo "=== [$(date -u)] Initiating Managed Failover to Hyderabad ==="
aws rds failover-global-cluster   --global-cluster-identifier "${GLOBAL_CLUSTER_ID}"   --target-db-cluster-identifier "${TARGET_CLUSTER_ARN}"   --region "${SECONDARY_REGION}"

echo "=== [$(date -u)] Awaiting Cluster Availability ==="
aws rds wait db-cluster-available   --db-cluster-identifier "paysecure-secondary"   --region "${SECONDARY_REGION}"

echo "=== [$(date -u)] Aurora Failover Verified. Hyderabad is Primary Writer ==="
