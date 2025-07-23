#!/bin/bash
set -euo pipefail

# Script to install Venafi Cloud components for Istio integration
# Usage: ./install-venafi-components.sh

echo "Installing Venafi Cloud components for Istio integration"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo "Checking prerequisites..."
for cmd in kubectl helm; do
    if ! command_exists "$cmd"; then
        echo "Error: $cmd is not installed. Please install it first."
        exit 1
    fi
done

# Check if cluster is accessible
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: Cannot connect to Kubernetes cluster. Please ensure kubectl is configured."
    exit 1
fi

# Install venctl if not present
if ! command_exists venctl; then
    echo "Installing venctl CLI..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command_exists brew; then
            brew install venafi/tap/venctl
        else
            curl -sSfL https://dl.venafi.cloud/venctl/latest/installer.sh | bash
        fi
    else
        curl -sSfL https://dl.venafi.cloud/venctl/latest/installer.sh | bash
    fi
    echo "venctl installed successfully"
else
    echo "venctl already installed: $(venctl version)"
fi

# Check environment variables
if [[ -z "${VENAFI_CLOUD_API_KEY:-}" ]]; then
    echo "Warning: VENAFI_CLOUD_API_KEY not set. You'll need to configure authentication manually."
    echo "Run: venctl auth --api-key YOUR_API_KEY"
else
    echo "Authenticating with Venafi Cloud..."
    venctl auth --api-key "$VENAFI_CLOUD_API_KEY"
fi

# Create required namespaces
echo ""
echo "Creating Kubernetes namespaces..."
kubectl create namespace venafi --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

# Create Venafi credentials secret if API key is provided
if [[ -n "${VENAFI_CLOUD_API_KEY:-}" ]]; then
    echo "Creating Venafi credentials secret..."
    kubectl create secret generic venafi-credentials \
        --namespace=istio-system \
        --from-literal=api-key="$VENAFI_CLOUD_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
fi

# Generate and apply Venafi components manifest
echo ""
echo "Generating Venafi components manifest..."
venctl components kubernetes manifest generate \
    --region us \
    --cert-manager \
    --istio-csr \
    --default-approver > venafi-components.yaml

echo "Applying Venafi components..."
ISTIO_TRUST_DOMAIN="${ISTIO_TRUST_DOMAIN:-cluster.local}" \
venctl components kubernetes manifest tool sync \
    --file venafi-components.yaml

# Wait for components to be ready
echo ""
echo "Waiting for Venafi components to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager -n venafi --timeout=300s || {
    echo "Warning: cert-manager pods may still be starting"
}

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager-istio-csr -n venafi --timeout=300s || {
    echo "Warning: istio-csr pods may still be starting"
}

# Create Venafi Cloud issuer if zone is provided
if [[ -n "${VENAFI_ZONE:-}" ]] && [[ -n "${VENAFI_CLOUD_API_KEY:-}" ]]; then
    echo ""
    echo "Creating Venafi Cloud issuer..."
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: venafi-cloud-issuer
spec:
  venafi:
    cloud:
      apiTokenSecretRef:
        name: venafi-credentials
        key: api-key
      url: https://api.venafi.cloud/v1
    zone: "$VENAFI_ZONE"
EOF
    
    # Wait for issuer to be ready
    echo "Waiting for Venafi issuer to be ready..."
    sleep 30
    kubectl wait --for=condition=ready clusterissuer/venafi-cloud-issuer --timeout=120s || {
        echo "Warning: Venafi issuer may still be initializing"
    }
else
    echo ""
    echo "Skipping Venafi Cloud issuer creation. Set VENAFI_ZONE and VENAFI_CLOUD_API_KEY to create automatically."
fi

# Verify installation
echo ""
echo "Verifying Venafi components installation..."
echo ""
echo "Venafi namespace pods:"
kubectl get pods -n venafi

echo ""
echo "ClusterIssuers:"
kubectl get clusterissuer

echo ""
echo "CRDs installed:"
kubectl get crd | grep -E "(cert-manager|venafi)" | head -10

# Show next steps
echo ""
echo "Venafi components installation completed successfully!"
echo ""
echo "Components installed:"
echo "- cert-manager in 'venafi' namespace"
echo "- istio-csr integration components"
echo "- Default approver for certificate management"

if [[ -n "${VENAFI_ZONE:-}" ]] && [[ -n "${VENAFI_CLOUD_API_KEY:-}" ]]; then
    echo "- Venafi Cloud issuer: venafi-cloud-issuer"
fi

echo ""
echo "Next steps:"
echo "1. Install Istio with Venafi integration: ./install-istio-venafi.sh"
echo "2. Deploy test applications: ./deploy-test-app.sh"
echo "3. Check the README.md for detailed validation steps"

# Cleanup
rm -f venafi-components.yaml