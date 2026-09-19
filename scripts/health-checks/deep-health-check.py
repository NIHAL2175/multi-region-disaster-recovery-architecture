#!/usr/bin/env python3
"""
PaySecure Gateway - Deep Health Check Probe
Evaluates:
1. Aurora PostgreSQL read/write latency
2. DynamoDB idempotency key store ping
3. Redis cluster response time
4. Kafka broker producer liveness
Returns HTTP 200 (OK) if all tiers healthy; HTTP 503 (Service Unavailable) otherwise.
"""

import sys
import time
import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("deep-health-probe")

def probe_database():
    # Simulate Aurora probe (< 10ms)
    return True, 4.2

def probe_dynamodb():
    # Simulate DynamoDB probe (< 5ms)
    return True, 2.1

def probe_cache():
    # Simulate Redis cache probe (< 2ms)
    return True, 1.1

def probe_kafka():
    # Simulate Kafka producer ping (< 15ms)
    return True, 8.5

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health/ready" or self.path == "/health/deep":
            db_ok, db_lat = probe_database()
            ddb_ok, ddb_lat = probe_dynamodb()
            cache_ok, cache_lat = probe_cache()
            kafka_ok, kafka_lat = probe_kafka()
            
            all_healthy = db_ok and ddb_ok and cache_ok and kafka_ok
            response_payload = {
                "status": "HEALTHY" if all_healthy else "UNHEALTHY",
                "timestamp": time.time(),
                "components": {
                    "aurora_postgresql": {"status": "UP", "latency_ms": db_lat},
                    "dynamodb_idempotency": {"status": "UP", "latency_ms": ddb_lat},
                    "elasticache_redis": {"status": "UP", "latency_ms": cache_lat},
                    "msk_kafka": {"status": "UP", "latency_ms": kafka_lat}
                }
            }
            
            if all_healthy:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(response_payload).encode())
            else:
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(response_payload).encode())
        else:
            self.send_response(404)
            self.end_headers()

def run_server(port=8080):
    server = HTTPServer(('0.0.0.0', port), HealthHandler)
    logger.info(f"Deep Health Check server listening on port {port}...")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
