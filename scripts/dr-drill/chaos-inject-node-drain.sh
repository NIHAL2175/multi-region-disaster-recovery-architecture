#!/usr/bin/env bash
set -euo pipefail

# PaySecure Gateway - Chaos Engineering: AZ Failure Simulation
# Evicts pods from worker nodes in ap-south-1a to simulate AZ loss
echo "=== [$(date -u)] Initiating Worker Node Drain in ap-south-1a ==="
TARGET_NODES=$(kubectl get nodes -l topology.kubernetes.io/zone=ap-south-1a -o jsonpath='{.items[*].metadata.name}')

for NODE in ${TARGET_NODES}; do
  echo "Cordoning and draining node: ${NODE}..."
  kubectl cordon "${NODE}"
  kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30
done

echo "=== [$(date -u)] AZ ap-south-1a Drained. Validating Pod Rescheduling ==="
kubectl -n paysecure get pods -o wide
