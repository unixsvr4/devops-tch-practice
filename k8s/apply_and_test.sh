# Apply and test
kubectl apply -f k8s/policies/no-privileged.yaml

# Try to deploy a privileged pod — should be REJECTED
kubectl run bad-pod --image=nginx \
  --overrides='{"spec":{"containers":[{"name":"bad","image":"nginx","securityContext":{"privileged":true}}]}}'
# Expected: Error from server: admission webhook denied the request
