# PaySecure Gateway: Zero-Downtime Planned Region Migration Procedure

**Document ID**: PSG-SANDBOX-004-MIG  
**Scope**: Controlled, Planned Shift of Production Workloads from Mumbai to Hyderabad  
**Methodology**: Canary & Linear Traffic Shifting (Weighted DNS & Anycast Routing)  
**Expected Downtime**: EXACTLY 0.00 Seconds (Zero Dropped Calls)  

---

## 1. Executive Summary & Use Cases

While Disaster Recovery is *reactive* (responding to sudden infrastructure failures), **Planned Region Migration** is *proactive*. Planned migrations are executed for:
1. Scheduled electrical and hardware maintenance of primary data centre facilities.
2. Production DR Drill testing during business hours without customer impact.
3. Permanent migration to a newly launched cloud facility.

---

## 2. Linear Traffic Shifting Workflow (The 6-Phase Protocol)

```
+---------------------------------------------------------------------------------------------------+
| PaySecure Zero-Downtime Region Migration Execution Timeline (Duration: 60 Minutes)                |
+-------+--------------------+-----------------------------------------------+----------------------+
| Phase | Time Window        | Operational Action & Traffic Distribution     | Validation Gate      |
+-------+--------------------+-----------------------------------------------+----------------------+
| 1     | T - 30 Minutes     | Pre-flight synchronization: Scale Hyderabad   | 24 EKS Nodes Ready;  |
|       |                    | EKS to 100% capacity (24 nodes, 180 pods).    | Replication Lag < 200|
+-------+--------------------+-----------------------------------------------+----------------------+
| 2     | T + 00 to T + 10m  | Canary Ingress: Route 53 Weighted DNS shifts  | Canary Error Rate    |
|       |                    | 5% traffic to Hyderabad; 95% remains Mumbai.  | < 0.01%; Latency 190m|
+-------+--------------------+-----------------------------------------------+----------------------+
| 3     | T + 10 to T + 25m  | Linear Ramp: Route 53 weights adjust:         | Both regions share   |
|       |                    | 25% -> 50% -> 75% traffic to Hyderabad.       | load seamlessly      |
+-------+--------------------+-----------------------------------------------+----------------------+
| 4     | T + 25 to T + 30m  | Database Planned Switchover: Execute managed  | Zero Data Loss;      |
|       |                    | Aurora planned switchover (aws rds failover). | DB switch in ~25 sec |
+-------+--------------------+-----------------------------------------------+----------------------+
| 5     | T + 30 to T + 45m  | Final Cutover: 100% traffic shifted to Hyd;   | Zero HTTP 5xx errors;|
|       |                    | Mumbai ALB receives 0% production queries.    | All txns authorized  |
+-------+--------------------+-----------------------------------------------+----------------------+
| 6     | T + 45 to T + 60m  | Post-Migration Sign-Off: Downscale Mumbai EKS | Hyderabad established|
|       |                    | to standby capacity (12 nodes); audit ledgers.| as active primary    |
+-------+--------------------+-----------------------------------------------+----------------------+
```

### Managed Aurora Switchover Command
Because Mumbai is fully healthy during a planned migration, we execute a **managed zero-data-loss switchover** rather than a destructive detachment:
```bash
aws rds failover-global-cluster   --global-cluster-identifier paysecure-global   --target-db-cluster-identifier arn:aws:rds:ap-south-2:123456789012:cluster:paysecure-secondary
```
Aurora coordinates with the Mumbai primary, flushes all write-ahead log buffers, synchronizes storage blocks, and switches roles seamlessly in **under 25 seconds** without a single transaction dropped!
