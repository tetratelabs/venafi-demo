#!/bin/bash
set -euo pipefail

# Install Istio with automatic certificate reloading
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

# Install Istio with auto-reload
cat <<EOF | istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
spec:
  components:
    pilot:
      k8s:
        env:
          - name: AUTO_RELOAD_PLUGIN_CERTS
            value: "true"
EOF

# Wait for istiod
kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s

echo "✅ Istio installed with auto-reload enabled"