#!/bin/bash
set -euo pipefail

# Install Istio (automatic certificate reloading is enabled by default)
ISTIO_VERSION="1.25.2"

echo "Installing Istio ${ISTIO_VERSION}..."

# Check prerequisites
if ! command -v istioctl >/dev/null 2>&1; then
    echo "Installing istioctl..."
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
    export PATH=$PWD/istio-${ISTIO_VERSION}/bin:$PATH
fi

# Check CA certificate
if ! kubectl get secret cacerts -n istio-system >/dev/null 2>&1; then
    echo "Error: cacerts secret not found. Run setup-venafi-ca.sh or setup-self-signed-ca.sh first"
    exit 1
fi

# Install Istio (default configuration)
istioctl install -y

# Wait for istiod
kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s

echo "✅ Istio installed (certificate auto-reload is enabled by default)"