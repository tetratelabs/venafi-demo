#!/bin/bash
set -euo pipefail

# Setup self-signed CA for CI/testing (NOT for production)
echo "⚠️  Setting up self-signed CA (for testing only)..."

# Create istio-system namespace
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

# Create self-signed issuer
echo "Creating self-signed issuer..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: self-signed-issuer
spec:
  selfSigned: {}
EOF

# Wait for issuer
sleep 5

# Create Istio CA certificate
echo "Creating self-signed Istio CA certificate..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  secretName: cacerts
  duration: 2160h    # 90 days
  renewBefore: 360h  # 15 days
  isCA: true
  commonName: istio-ca
  issuerRef:
    name: self-signed-issuer
    kind: ClusterIssuer
EOF

# Wait for certificate
kubectl wait --for=condition=ready certificate/istio-ca -n istio-system --timeout=120s

echo "✅ Self-signed CA setup complete (testing only)"
echo "⚠️  For production, use setup-venafi-ca.sh instead"