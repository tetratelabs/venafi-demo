#!/bin/bash
set -euo pipefail

# Script to deploy test applications with Venafi-managed mTLS
# Usage: ./deploy-test-app.sh

echo "Deploying test applications with Venafi-managed mTLS..."
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
    echo "Error: istio-system namespace not found. Please install Istio with Venafi integration first."
    exit 1
fi

# Check if Venafi components are installed
if ! kubectl get namespace venafi &>/dev/null; then
    echo "Error: venafi namespace not found. Please install Venafi components first."
    exit 1
fi

# Use test-app namespace (should already be created by install-istio-venafi.sh)
echo "Verifying test-app namespace with Istio injection..."
if ! kubectl get namespace test-app &>/dev/null; then
    echo "Creating test-app namespace with Istio injection enabled..."
    kubectl create namespace test-app
fi

kubectl label namespace test-app istio-injection=enabled --overwrite

# Deploy test applications
echo ""
echo "Deploying httpbin service..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-app
  labels:
    istio-injection: enabled
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: test-app
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
  namespace: test-app
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl
  namespace: test-app
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
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: test-app
spec:
  mtls:
    mode: STRICT
EOF

# Wait for deployments to be ready
echo ""
echo "Waiting for httpbin deployment to be ready..."
kubectl wait --for=condition=ready pod -l app=httpbin -n test-app --timeout=180s

echo "Waiting for curl deployment to be ready..."
kubectl wait --for=condition=ready pod -l app=curl -n test-app --timeout=180s

# Give additional time for sidecars to initialize
echo "Allowing time for Istio sidecars to initialize..."
sleep 30

# Verify deployment
echo ""
echo "Deployed resources:"
kubectl get all -n test-app

# Test mTLS communication
echo ""
echo "Testing mTLS communication with Venafi-managed certificates..."
echo "Running: curl http://httpbin:8000/headers"
kubectl exec -n test-app deployment/curl -- curl -s http://httpbin:8000/headers | jq . || \
    kubectl exec -n test-app deployment/curl -- curl -s http://httpbin:8000/headers

# Check proxy configuration
echo ""
echo "Checking proxy certificates..."
if command_exists istioctl; then
    echo "Sidecar certificate secrets for httpbin:"
    istioctl proxy-config secret deployment/httpbin -n test-app
    
    echo ""
    echo "Certificate issuer from sidecar (should show Venafi CA):"
    istioctl pc secret deployment/httpbin.test-app -o json | \
      jq -r '.dynamicActiveSecrets[] | select(.name == "default") | .secret.tlsCertificate.certificateChain.inlineBytes' | \
      base64 -d | openssl x509 -text -noout | grep -A2 "Issuer" || echo "Certificate not ready yet"
    
    echo ""
    echo "Certificate serial number:"
    istioctl pc secret deployment/httpbin.test-app -o json | \
      jq -r '.dynamicActiveSecrets[] | select(.name == "default") | .secret.tlsCertificate.certificateChain.inlineBytes' | \
      base64 -d | openssl x509 -serial -noout || echo "Certificate not ready yet"
      
    echo ""
    echo "Verifying certificate chain shows Venafi origin:"
    istioctl pc secret deployment/httpbin.test-app -o json | \
      jq -r '.dynamicActiveSecrets[] | select(.name == "default") | .secret.tlsCertificate.certificateChain.inlineBytes' | \
      base64 -d | openssl x509 -text -noout | grep -E "(Subject|Issuer)" || echo "Certificate details not available"
else
    echo "istioctl not found. Install it to view detailed proxy configuration."
fi

echo ""
echo "Test applications deployed successfully with Venafi-managed certificates!"
echo ""
echo "Venafi Integration Verification:"
echo "1. Check Venafi Cloud dashboard for issued certificates"
echo "2. Verify certificate policies are enforced"
echo "3. Monitor certificate usage and compliance"
echo ""
echo "Manual Testing Commands:"
echo "  # Test mTLS communication"
echo "  kubectl exec -it -n test-app deployment/curl -- sh"
echo "  curl http://httpbin:8000/headers"
echo ""
echo "  # View certificate details"
echo "  istioctl pc secret deployment/httpbin.test-app -o json | jq ."
echo ""
echo "  # Check Venafi issuer status"
echo "  kubectl describe clusterissuer venafi-cloud-issuer"
echo ""
echo "  # Monitor certificate requests"
echo "  kubectl get certificaterequests -A"
echo ""
echo "Cleanup:"
echo "  kubectl delete namespace test-app"