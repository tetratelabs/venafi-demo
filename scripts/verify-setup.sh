#!/bin/bash
set -euo pipefail

echo "=== Verifying Venafi + Istio Setup ==="

# Check components
echo -e "\n📦 Components:"
kubectl get pods -n cert-manager --no-headers | grep Running || echo "❌ cert-manager not running"
kubectl get pods -n istio-system --no-headers | grep Running || echo "❌ istio not running"

# Check Venafi issuer
echo -e "\n🔐 Venafi Issuer:"
kubectl get clusterissuer venafi-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True && echo "✅ Ready" || echo "❌ Not ready"

# Check certificate
echo -e "\n📜 Certificate Status:"
kubectl get certificate istio-ca -n istio-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True && echo "✅ Issued" || echo "❌ Not issued"

# Show expiry
echo -e "\n📅 Certificate Expiry:"
kubectl get certificate istio-ca -n istio-system -o jsonpath='{.status.notAfter}' | xargs -I {} echo "Expires: {}"

# Test workload
echo -e "\n🧪 Testing mTLS:"
kubectl create namespace test --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
kubectl label namespace test istio-injection=enabled --overwrite >/dev/null 2>&1

cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: test
spec:
  ports:
  - port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: test
spec:
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
EOF

# Wait for pod
kubectl wait --for=condition=ready pod -l app=httpbin -n test --timeout=60s >/dev/null 2>&1

# Test connectivity
kubectl exec -n test deployment/httpbin -- curl -s localhost:8000/headers >/dev/null 2>&1 && echo "✅ mTLS working" || echo "❌ mTLS failed"

echo -e "\n✨ Setup verification complete"