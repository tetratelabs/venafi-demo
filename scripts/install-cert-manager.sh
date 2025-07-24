#!/bin/bash
set -euo pipefail

# Install cert-manager for certificate lifecycle management
CERT_MANAGER_VERSION="v1.18.2"

echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."

# Check prerequisites
if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found"
    exit 1
fi

# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

# Wait for cert-manager to be ready
echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s

echo "✅ cert-manager installed successfully"