#!/bin/bash
# TCH DevOps Practice — full stack startup
# Requires: OrbStack running (provides arm64 Docker + Kubernetes)

set -euo pipefail
cd "$(dirname "$0")"

echo "Starting TCH DevOps Practice stack..."

docker compose up -d --build

echo ""
echo "Services starting. Elasticsearch takes ~40s to become healthy."
echo ""
echo "  Payment App   → http://localhost:8080/health"
echo "  Prometheus    → http://localhost:9090"
echo "  Alertmanager  → http://localhost:9093"
echo "  Grafana       → http://localhost:3000  (admin / admin)"
echo "  Kibana        → http://localhost:5601"
echo "  Vault UI      → http://localhost:8200  (token: root)"
echo ""
echo "Watch startup:  docker compose logs -f elasticsearch app"
echo ""
echo "Next steps:"
echo "  1. Generate traffic:  bash generate_traffic.sh &"
echo "  2. Vault demo:        bash ../k8s/vault/dev_mode.sh"
echo "  3. K8s hardening:     bash ../k8s/apply_and_test.sh"
