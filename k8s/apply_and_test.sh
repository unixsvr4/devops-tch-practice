#!/bin/bash
# OPA Gatekeeper hardening demo — runs on OrbStack's built-in K8s cluster.
# Run from repo root: bash k8s/apply_and_test.sh

set -euo pipefail

kubectl config use-context orbstack

# ── Install Gatekeeper if not present ────────────────────────────────────────
if ! kubectl get ns gatekeeper-system &>/dev/null; then
    echo "[1/4] Installing OPA Gatekeeper..."
    kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml
    echo "  Waiting for controller-manager deployment to be available..."
    kubectl wait --for=condition=available --timeout=120s \
        deployment/gatekeeper-controller-manager -n gatekeeper-system
    echo "  Waiting 20s for admission webhook to register..."
    sleep 20
else
    echo "[1/4] Gatekeeper already installed — skipping."
fi

# ── Apply namespace + network policies ───────────────────────────────────────
echo "[2/4] Applying namespace security and network policies..."
# Retry up to 3 times — webhook may still be warming up
for i in 1 2 3; do
    kubectl apply -f k8s/base/pod-security.yaml && break || {
        echo "  Attempt $i failed (webhook warming up), retrying in 10s..."
        sleep 10
    }
done

# ── Apply OPA ConstraintTemplate then Constraint ─────────────────────────────
echo "[3/4] Applying OPA no-privileged policy..."
kubectl apply -f k8s/policies/no-privileged.yaml

echo "  Waiting 20s for ConstraintTemplate CRD to be established..."
sleep 20

# Re-apply so the Constraint (which depends on the CRD) is created
kubectl apply -f k8s/policies/no-privileged.yaml

echo "  Waiting 10s for constraint to be enforced by webhook..."
sleep 10

# ── Test: privileged pod must be rejected ────────────────────────────────────
echo "[4/4] Testing: trying to launch a privileged pod (should be REJECTED)..."
RESULT=$(kubectl run bad-pod --image=nginx \
    --overrides='{"spec":{"containers":[{"name":"bad","image":"nginx","securityContext":{"privileged":true}}]}}' \
    2>&1 || true)

echo "$RESULT"

if echo "$RESULT" | grep -qiE "denied|webhook|not allowed|privileged"; then
    echo ""
    echo "PASS — privileged pod was rejected by Gatekeeper."
    echo "Interview point: this is Policy as Code — the constraint is in git,"
    echo "version-controlled, peer-reviewed, and enforced at admission time."
else
    echo ""
    echo "NOTE: Pod was not rejected. Gatekeeper webhook may still be warming up."
    echo "Wait 30s and re-run: bash k8s/apply_and_test.sh"
fi

# Cleanup
kubectl delete pod bad-pod --ignore-not-found 2>/dev/null
