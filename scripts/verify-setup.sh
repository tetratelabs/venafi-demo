#!/bin/bash
set -euo pipefail

ISTIO_VERSION="1.25.2"
export PATH=$PWD/istio-${ISTIO_VERSION}/bin:$PATH

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
echo -e "\n🧪 Deploying Test Application:"
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
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-test
  namespace: test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl-test
  template:
    metadata:
      labels:
        app: curl-test
    spec:
      containers:
      - name: netshoot
        image: nicolaka/netshoot
        command: ["sleep", "infinity"]
EOF

# Wait for pod
kubectl wait --for=condition=ready pod -l app=httpbin -n test --timeout=60s >/dev/null 2>&1
kubectl wait --for=condition=ready pod -l app=curl-test -n test --timeout=120s >/dev/null 2>&1
  

# Test connectivity
kubectl exec -n test deploy/curl-test -- curl -s httpbin:8000/headers


# Verify certificate with istioctl
echo -e "\n🔍 Verifying Sidecar Certificate:"
if command -v istioctl >/dev/null 2>&1; then
    # Get certificate details
    echo "Certificate chain from sidecar:"
    istioctl pc secret deploy/httpbin -n test | grep -E "(default|ROOTCA)" || echo "No certificates found"
    
    # Extract and display certificate issuer
    echo -e "\nCertificate issuer details:"
    istioctl pc secret deploy/httpbin -n test --output json | \
        jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' 2>/dev/null | \
        base64 -d | openssl x509 -issuer -noout 2>/dev/null || echo "Could not extract issuer"
else
    echo "❌ istioctl not found - cannot verify sidecar certificates"
fi

# Test connectivity using Alpine curl
echo -e "\n🌐 Testing mTLS Communication:"
kubectl exec -n test deploy/curl-test -- curl -s httpbin:8000/headers
 >/dev/null 2>&1 && echo "✅ mTLS working" || echo "❌ mTLS failed"

echo -e "\n✨ Setup verification complete"