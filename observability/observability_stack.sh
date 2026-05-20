# Run the observability stack
cd observability
docker compose up -d

# Open Grafana: http://localhost:3000 (admin/admin)
# Open Kibana:  http://localhost:5601
# Open Prometheus: http://localhost:9090
# Practice PromQL queries
# Error rate:
# sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# p99 latency:
# histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))

# Memory usage:
# container_memory_usage_bytes{namespace="payment-app"} / container_spec_memory_limit_bytes > 0.8
