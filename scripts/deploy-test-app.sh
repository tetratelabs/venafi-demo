#!/bin/bash
set -euo pipefail

# Script to deploy a test application with mTLS enabled
# Usage: ./deploy-test-app.sh

echo "Deploying test application with mTLS..."
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo "Checking prerequisites..."
if ! command_exists kubectl; then
    echo "Error: kubectl is not installed. Please install it first."
    exit 1
fi

# Check if Istio is installed
if ! kubectl get namespace istio-system &>/dev/null; then
    echo "Error: istio-system namespace not found. Please install TID first."
    exit 1
fi

# Deploy test application
echo "Creating test-mtls namespace with Istio injection enabled..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-mtls
  labels:
    istio-injection: enabled
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: test-mtls
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
      - image: docker.io/kennethreitz/httpbin
        name: httpbin
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: test-mtls
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: test-mtls
spec:
  mtls:
    mode: STRICT
EOF

# Wait for deployment to be ready
echo ""
echo "Waiting for httpbin deployment to be ready..."
kubectl wait --for=condition=ready pod -l app=httpbin -n test-mtls --timeout=180s

# Deploy a client pod for testing
echo ""
echo "Deploying client pod for testing..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl
  namespace: test-mtls
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl
  template:
    metadata:
      labels:
        app: curl
    spec:
      containers:
      - image: curlimages/curl:latest
        name: curl
        command: ["/bin/sh", "-c", "sleep 3600"]
EOF

# Wait for client pod to be ready
echo ""
echo "Waiting for curl client to be ready..."
kubectl wait --for=condition=ready pod -l app=curl -n test-mtls --timeout=180s

# Verify deployment
echo ""
echo "Deployed resources:"
kubectl get all -n test-mtls

# Test mTLS communication
echo ""
echo "Testing mTLS communication..."
echo "Running: curl http://httpbin:8000/headers"
kubectl exec -n test-mtls deployment/curl -- curl -s http://httpbin:8000/headers | jq . || \
    kubectl exec -n test-mtls deployment/curl -- curl -s http://httpbin:8000/headers

# Check proxy configuration
echo ""
echo "Checking proxy certificates..."
if command_exists istioctl; then
    echo "Certificate chain for httpbin:"
    istioctl proxy-config secret deployment/httpbin -n test-mtls | grep -E "ROOTCA|default" || echo "No certificates found yet"
else
    echo "istioctl not found. Install it to view detailed proxy configuration."
fi

echo ""
echo "Test application deployed successfully!"
echo ""
echo "To test mTLS manually:"
echo "  kubectl exec -it -n test-mtls deployment/curl -- sh"
echo "  curl http://httpbin:8000/headers"
echo ""
echo "To check certificate details:"
echo "  kubectl exec -n test-mtls deployment/httpbin -c istio-proxy -- openssl s_client -connect httpbin:8000 -showcerts"
echo ""
echo "To remove test application:"
echo "  kubectl delete namespace test-mtls"