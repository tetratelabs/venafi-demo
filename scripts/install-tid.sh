#!/bin/bash
set -euo pipefail

# Script to install Tetrate Istio Distribution (TID)
# Usage: ./install-tid.sh [VERSION] [TAG]

# Default versions
DEFAULT_VERSION="1.24.0+tetrate0"
DEFAULT_TAG="1.24.0-tetrate0"

# Use provided versions or defaults
VERSION="${1:-$DEFAULT_VERSION}"
TAG="${2:-$DEFAULT_TAG}"

echo "Installing Tetrate Istio Distribution"
echo "Version: $VERSION"
echo "Tag: $TAG"
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

# Add Tetrate Helm repository
echo "Adding Tetrate Helm repository..."
helm repo add tetratelabs https://tis.tetrate.io/charts
helm repo update tetratelabs

# Show available versions
echo ""
echo "Available TID versions:"
helm search repo tetratelabs/base --versions | head -10

# Create istio-system namespace
echo ""
echo "Creating istio-system namespace..."
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

# Install Istio base components
echo ""
echo "Installing Istio base components..."
helm upgrade --install istio-base tetratelabs/base \
    -n istio-system \
    --set global.tag="$TAG" \
    --set global.hub="containers.istio.tetratelabs.com" \
    --version "$VERSION" \
    --wait

# Create istiod values file with CA rotation support
echo ""
echo "Creating istiod configuration..."
cat > /tmp/istiod-values.yaml <<EOF
global:
  tag: $TAG
  hub: "containers.istio.tetratelabs.com"

pilot:
  env:
    # Enable automatic certificate reload
    AUTO_RELOAD_PLUGIN_CERTS: "true"
    # Certificate rotation check interval
    PILOT_CERT_CHECK_INTERVAL: "1m"

meshConfig:
  defaultConfig:
    proxyStatsMatcher:
      inclusionRegexps:
      - ".*circuit_breakers.*"
      - ".*osconfig.*"
      - ".*outlier_detection.*"
      - ".*_retry.*"
EOF

# Install istiod
echo ""
echo "Installing istiod..."
helm upgrade --install istiod tetratelabs/istiod \
    -n istio-system \
    -f /tmp/istiod-values.yaml \
    --version "$VERSION" \
    --wait


# Verify installation
echo ""
echo "Verifying installation..."
echo ""
echo "Helm releases:"
helm ls -A | grep -E "istio|NAME"

echo ""
echo "Istio system pods:"
kubectl get pods -n istio-system

# Check istioctl if available
if command_exists istioctl; then
    echo ""
    echo "Istio version:"
    istioctl version
fi

# Cleanup
rm -f /tmp/istiod-values.yaml

echo ""
echo "TID installation completed successfully!"
echo ""
echo "Components installed:"
echo "- Istio base components"
echo "- Istiod control plane with CA auto-reload enabled"
echo ""
echo "Next steps:"
echo "1. Install cert-manager: ./setup-ca-rotation.sh"
echo "2. Deploy a test application to verify mTLS"
echo "3. Check the README.md for detailed instructions"