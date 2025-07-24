#!/bin/bash
set -euo pipefail

# Setup Venafi Cloud as Istio CA issuer
echo "Setting up Venafi Cloud CA issuer..."

# Check environment variables
if [[ -z "${VENAFI_API_KEY:-}" ]]; then
    echo "Error: VENAFI_API_KEY not set"
    exit 1
fi

if [[ -z "${VENAFI_ZONE:-}" ]]; then
    echo "Error: VENAFI_ZONE not set"
    exit 1
fi

# Create istio-system namespace
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

# Create Venafi credentials secret
echo "Creating Venafi credentials..."
kubectl create secret generic venafi-credentials \
  --namespace=cert-manager \
  --from-literal=api-key="$VENAFI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create Venafi ClusterIssuer
echo "Creating Venafi issuer..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: venafi-issuer
spec:
  venafi:
    zone: "$VENAFI_ZONE"
    cloud:
      apiTokenSecretRef:
        name: venafi-credentials
        key: api-key
EOF

# Wait for issuer
sleep 10

# Create Istio CA certificate
echo "Creating Istio CA certificate..."
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
    name: venafi-issuer
    kind: ClusterIssuer
EOF

# Wait for certificate
kubectl wait --for=condition=ready certificate/istio-ca -n istio-system --timeout=120s

echo "✅ Venafi CA setup complete"