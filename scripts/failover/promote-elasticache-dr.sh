#!/usr/bin/env bash
set -euo pipefail

# PaySecure Gateway - ElastiCache Global Datastore Secondary Promotion
GLOBAL_DATASTORE_ID="paysecure-redis-global"
DR_REPLICATION_GROUP="paysecure-redis-hyd"
SECONDARY_REGION="ap-south-2"

echo "=== [$(date -u)] Disassociating & Promoting Hyderabad Redis Global Datastore ==="
aws elasticache failover-global-replication-group   --global-replication-group-id "${GLOBAL_DATASTORE_ID}"   --primary-region "${SECONDARY_REGION}"   --primary-replication-group-id "${DR_REPLICATION_GROUP}"   --region "${SECONDARY_REGION}"

echo "=== [$(date -u)] ElastiCache Promotion Triggered ==="
