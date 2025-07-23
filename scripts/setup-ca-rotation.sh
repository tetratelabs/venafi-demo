#!/bin/bash
set -euo pipefail

# Script to setup automated CA rotation for Istio using cert-manager
# Usage: ./setup-ca-rotation.sh

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.13.3}"

echo "Setting up automated CA rotation for Istio"
echo "cert-manager version: $CERT_MANAGER_VERSION"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to wait for deployment
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-180}
    
    echo "Waiting for deployment $deployment in namespace $namespace..."
    kubectl wait --for=condition=available deployment/$deployment -n $namespace --timeout=${timeout}s
}

# Check prerequisites
echo "Checking prerequisites..."
if ! command_exists kubectl; then
    echo "Error: kubectl is not installed. Please install it first."
    exit 1
fi

# Check if cluster is accessible
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: Cannot connect to Kubernetes cluster. Please ensure kubectl is configured."
    exit 1
fi

# Check if Istio is installed
if ! kubectl get namespace istio-system &>/dev/null; then
    echo "Error: istio-system namespace not found. Please install TID first using ./install-tid.sh"
    exit 1
fi

# Install cert-manager
echo ""
echo "Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

# Wait for cert-manager to be ready
echo ""
echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=180s

# Create self-signed root CA
echo ""
echo "Creating self-signed root CA..."
cat <<EOF | kubectl apply -f -
---
# Self-signed root CA issuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
# Root CA Certificate
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: root-ca
  secretName: root-ca-secret
  duration: 87600h # 10 years
  renewBefore: 720h # 30 days
  privateKey:
    algorithm: RSA
    encoding: PKCS1
    size: 4096
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
# Root CA Issuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: root-ca-issuer
spec:
  ca:
    secretName: root-ca-secret
EOF

# Wait for root CA to be ready
echo ""
echo "Waiting for root CA to be ready..."
kubectl wait --for=condition=ready certificate/root-ca -n cert-manager --timeout=60s

# Create Istio intermediate CA
echo ""
echo "Creating Istio intermediate CA with automatic rotation..."
cat <<EOF | kubectl apply -f -
---
# Istio Intermediate CA Certificate
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  isCA: true
  commonName: istio-ca
  secretName: cacerts
  duration: 1440h # 60 days
  renewBefore: 360h # 15 days before expiry
  privateKey:
    algorithm: RSA
    encoding: PKCS1
    size: 4096
  issuerRef:
    name: root-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
# Istio CA Issuer
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: istio-ca-issuer
  namespace: istio-system
spec:
  ca:
    secretName: cacerts
EOF

# Wait for Istio CA to be ready
echo ""
echo "Waiting for Istio CA to be ready..."
kubectl wait --for=condition=ready certificate/istio-ca -n istio-system --timeout=60s

# Restart istiod to pick up the new CA
echo ""
echo "Restarting istiod to load the new CA..."
kubectl rollout restart deployment/istiod -n istio-system
kubectl rollout status deployment/istiod -n istio-system --timeout=180s

# Verify CA setup
echo ""
echo "Verifying CA setup..."
echo ""
echo "Certificate status:"
kubectl get certificate -A

echo ""
echo "Istio CA certificate details:"
kubectl get certificate istio-ca -n istio-system -o yaml | grep -E "renewalTime:|notAfter:"

echo ""
echo "Certificate expiry information:"
if kubectl get secret cacerts -n istio-system -o json | jq -r '.data."ca-cert.pem"' | base64 -d | openssl x509 -text -noout > /dev/null 2>&1; then
    kubectl get secret cacerts -n istio-system -o json | \
        jq -r '.data."ca-cert.pem"' | \
        base64 -d | \
        openssl x509 -text -noout | \
        grep -A2 "Validity"
elif kubectl get secret cacerts -n istio-system -o json | jq -r '.data."tls.crt"' | base64 -d | openssl x509 -text -noout > /dev/null 2>&1; then
    kubectl get secret cacerts -n istio-system -o json | \
        jq -r '.data."tls.crt"' | \
        base64 -d | \
        openssl x509 -text -noout | \
        grep -A2 "Validity"
else
    echo "Certificate format not recognized. Available keys:"
    kubectl get secret cacerts -n istio-system -o json | jq -r '.data | keys[]'
fi

# Check if istiod picked up the new CA
echo ""
echo "Checking if istiod loaded the new CA..."
kubectl logs -n istio-system deployment/istiod --tail=50 | grep -i "ca cert" || echo "No CA cert logs found (this is normal if the pod just started)"

echo ""
echo "CA rotation setup completed successfully!"
echo ""
echo "Certificate rotation schedule:"
echo "- Root CA: 10 years validity, renews 30 days before expiry"
echo "- Istio CA: 60 days validity, renews 15 days before expiry"
echo ""
echo "Next steps:"
echo "1. Deploy a test application: ./deploy-test-app.sh"
echo "2. Monitor certificate renewal: kubectl describe certificate istio-ca -n istio-system"
echo "3. Check the README.md for troubleshooting tips"