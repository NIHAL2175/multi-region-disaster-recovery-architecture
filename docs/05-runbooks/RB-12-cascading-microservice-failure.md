# PaySecure DR Runbook: RB-12 Cascading Microservice Failure

## 1. Scenario Identification
- **Runbook ID**: RB-12
- **Scenario Name**: Cascading Failure Loop in `fraud-detection` Microservice Causing Gateway Timeouts
- **Category**: Application / Cascading Distributed Failure
- **Severity Classification**: P2 - High Availability Degradation
- **Target RTO**: Circuit Breaker Isolation < 60 Seconds; Full Stabilization < 3 Minutes
- **Target RPO**: Zero Transaction Loss (RPO = 0)
- **Affected Components**: `fraud-detection` microservice, `payment-api`, gRPC connection pools, Redis cache connection pool.
- **Incident Commander Role**: Principal Backend Architect / SRE Lead
- **Secondary Roles**: Lead Risk Engineer, Primary Application Developer

---

## 2. Detection Mechanism
1. **Transaction Success Rate Drop Alert**: `PaymentSuccessRateDropSevere`
   - Metric: Success rate drops from 99.8% to 42% over 10 minutes.
2. **gRPC Client Timeout Alert**: `PaymentApiGrpcTimeoutSpike`
   - Prometheus Alert: `rate(grpc_client_handling_seconds_count{grpc_service="FraudDetection",grpc_code="DeadlineExceeded"}[1m]) > 200`.
3. **Pod CrashLoopBackOff Alert**: `FraudDetectionCrashLoopHigh`
   - Kubernetes Alert: `rate(kube_pod_container_status_restarts_total{container="fraud-detection"}[5m]) > 10`.

---

## 3. Impact Assessment
- **Thread Starvation**: In-flight HTTP worker threads in `payment-api` hang waiting for 2,000 ms gRPC timeouts from `fraud-detection`.
- **Gateway Saturation**: P99 transaction latency explodes from 180 ms to > 2,800 ms, triggering upstream merchant timeouts.
- **Business Exposure**: Over 50% of legitimate customer checkout attempts rejected or abandoned.

---

## 4. Immediate Response (0–2 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **1** | Acknowledge Cascading Failure Alert | SRE Lead | `pd incident ack -i $APP_INCIDENT_ID` | Application War Room convened |
| **2** | Trip Circuit Breaker for Fraud Detection | SRE Lead | `kubectl -n paysecure patch configmap region-config --type merge -p '{"data":{"FRAUD_CIRCUIT_BREAKER_FORCED_OPEN":"true"}}'` | `payment-api` immediately short-circuits fraud gRPC calls |
| **3** | Enable Elevated Asynchronous Risk Monitoring | Risk Lead | `kubectl -n paysecure patch configmap region-config --type merge -p '{"data":{"FALLBACK_ASYNC_FRAUD_MODE":"true"}}'` | Transactions proceed with rule-based heuristics; detailed fraud ML evaluated asynchronously |
| **4** | Restart Saturated Payment API Pods | SRE Lead | `kubectl -n paysecure rollout restart deployment payment-api` | Clears deadlocked thread pools; frees worker memory |

---

## 5. Diagnostic Steps (2–5 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **5** | Inspect Fraud Detection Pod Crash Logs | App Dev | `kubectl -n paysecure logs -l app=fraud-detection --previous --tail=100` | Identifies `OutOfMemoryError: Java heap space` or infinite regex loop on malformed merchant metadata |
| **6** | Check Redis Connection Pool Saturation | SRE Lead | `aws cloudwatch get-metric-statistics --namespace AWS/ElastiCache --metric-name CurrConnections --dimensions Name=CacheClusterId,Value=paysecure-redis-001 --period 60 --statistics Maximum` | Confirms Redis connection limits are healthy |
| **7** | Isolate Toxic Request Payload | App Dev | Query Jaeger distributed tracing for slowest trace spans | Identifies specific malformed merchant payload triggering OOM loop |

---

## 6. Remediation & Stabilization Procedure (5–15 Minutes)
| Step # | Action | Executing Role | Specific Command / Operation | Expected Outcome |
| :-: | :--- | :--- | :--- | :--- |
| **8** | Deploy Hotfix Patch / Regex Sanitizer | App Dev | `kubectl -n paysecure set image deployment/fraud-detection fraud-detection=123456789012.dkr.ecr.ap-south-1.amazonaws.com/paysecure/fraud-detection:v2.4.2-hotfix` | Deploys memory-safe regex parsing fix |
| **9** | Increase Memory Limits on Fraud Pods | SRE Lead | `kubectl -n paysecure set resources deployment fraud-detection --limits=memory=4Gi --requests=memory=2Gi` | Allocates head-room to absorb backlog |
| **10** | Verify New Fraud Pods Pass Readiness Probes | SRE Lead | `kubectl -n paysecure rollout status deployment/fraud-detection` | 16 pods reach `Running` status |
| **11** | Transition Circuit Breaker to Half-Open Mode | SRE Lead | `kubectl -n paysecure patch configmap region-config --type merge -p '{"data":{"FRAUD_CIRCUIT_BREAKER_HALF_OPEN":"true"}}'` | 10% of transactions route through synchronous fraud check |
| **12** | Monitor Half-Open Latency & Error Rates | SRE Lead | `grpc_client_handling_seconds{grpc_service="FraudDetection",quantile="0.99"}` | Latency confirms healthy: 18 ms P99 |
| **13** | Fully Close Circuit Breaker | SRE Lead | `kubectl -n paysecure patch configmap region-config --type merge -p '{"data":{"FRAUD_CIRCUIT_BREAKER_FORCED_OPEN":"false","FRAUD_CIRCUIT_BREAKER_HALF_OPEN":"false"}}'` | 100% synchronous fraud screening safely restored |

---

## 7. Communication Protocol
- **Internal Engineering Advisory**: `Cascading failure in fraud-detection isolated via circuit breaker. Hotfix v2.4.2 deployed. Gateway success rate restored to 99.9%.`

---

## 8. Verification & Validation
- Check transaction success rate: `rate(http_requests_total{status="200"}[2m]) / rate(http_requests_total[2m]) > 0.998`.
- Check gateway P99 latency: `<= 180 ms`.

---

## 9. Rollback Procedure
If hotfix fails:
1. Re-open circuit breaker indefinitely.
2. Rely on secondary asynchronous fraud analysis queue for up to 4 hours.

---

## 10. Post-Incident Review Checklist
- [ ] Enforce strict gRPC deadlines (max 200 ms timeout) on all inter-service client stubs.
- [ ] Configure Istio Envoy circuit breaking rules (`maxConnections: 100`, `consecutive5xxErrors: 3`).
- [ ] Incorporate chaos latency injection test into CI/CD automated test suite.
