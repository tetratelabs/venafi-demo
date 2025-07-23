#!/bin/bash
set -euo pipefail

# Script to install Istio with Venafi Cloud integration
# Usage: ./install-istio-venafi.sh

echo "Installing Istio with Venafi Cloud integration"
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

if ! command_exists istioctl; then
    echo "Installing istioctl..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command_exists brew; then
            brew install istioctl
        else
            curl -L https://istio.io/downloadIstio | sh -
            export PATH=$PWD/istio-*/bin:$PATH
        fi
    else
        curl -L https://istio.io/downloadIstio | sh -
        export PATH=$PWD/istio-*/bin:$PATH
    fi
    echo "istioctl installed successfully"
fi

# Check if cluster is accessible
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: Cannot connect to Kubernetes cluster. Please ensure kubectl is configured."
    exit 1
fi

# Check if Venafi components are installed
if ! kubectl get namespace venafi &>/dev/null; then
    echo "Error: Venafi namespace not found. Please run ./install-venafi-components.sh first."
    exit 1
fi

# Set default values
ISTIO_TRUST_DOMAIN="${ISTIO_TRUST_DOMAIN:-cluster.local}"
VENAFI_ISSUER_NAME="${VENAFI_ISSUER_NAME:-venafi-cloud-issuer}"

echo "Using Istio trust domain: $ISTIO_TRUST_DOMAIN"
echo "Using Venafi issuer: $VENAFI_ISSUER_NAME"

# Create ConfigMap for istio-csr configuration
echo ""
echo "Creating istio-csr configuration..."
kubectl create configmap istio-csr-ca \
    --namespace=istio-system \
    --from-literal=issuer-name="$VENAFI_ISSUER_NAME" \
    --from-literal=issuer-kind=ClusterIssuer \
    --from-literal=issuer-group=cert-manager.io \
    --dry-run=client -o yaml | kubectl apply -f -

# Install istio-csr if not already installed by Venafi components
if ! kubectl get deployment cert-manager-istio-csr -n venafi &>/dev/null; then
    echo ""
    echo "Installing istio-csr via Helm..."
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update
    
    helm upgrade --install cert-manager-istio-csr jetstack/cert-manager-istio-csr \
        --namespace istio-system \
        --create-namespace \
        --set image.repository=quay.io/jetstack/cert-manager-istio-csr \
        --set app.tls.trustDomain="$ISTIO_TRUST_DOMAIN" \
        --set app.certmanager.issuer.name="$VENAFI_ISSUER_NAME" \
        --set app.certmanager.issuer.kind=ClusterIssuer \
        --set app.certmanager.issuer.group=cert-manager.io \
        --wait --timeout=300s
else
    echo "istio-csr already installed in venafi namespace"
fi

# Create Istio configuration for Venafi integration
echo ""
echo "Creating Istio configuration for Venafi integration..."
cat <<EOF > /tmp/istio-venafi-config.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: venafi-istio
  namespace: istio-system
spec:
  values:
    pilot:
      env:
        EXTERNAL_CA: true
        PILOT_CERT_PROVIDER: k8s.cluster.local
        ENABLE_CA_SERVER: false
    global:
      meshID: mesh1
      network: network1
      trustDomain: "$ISTIO_TRUST_DOMAIN"
  components:
    pilot:
      k8s:
        env:
          - name: CERT_SIGNER_DOMAIN
            value: "$VENAFI_ISSUER_NAME.cert-manager.io"
          - name: PILOT_CERT_PROVIDER
            value: k8s.cluster.local
          - name: EXTERNAL_CA
            value: "true"
        overlays:
          - apiVersion: apps/v1
            kind: Deployment
            name: istiod
            patches:
              - path: spec.template.spec.containers[name:discovery].env[name:PILOT_CERT_PROVIDER]
                value:
                  name: PILOT_CERT_PROVIDER
                  value: k8s.cluster.local
              - path: spec.template.spec.containers[name:discovery].env[name:EXTERNAL_CA]
                value:
                  name: EXTERNAL_CA
                  value: "true"
EOF

# Install Istio with Venafi integration
echo ""
echo "Installing Istio with Venafi integration..."
istioctl install -f /tmp/istio-venafi-config.yaml -y

# Wait for Istio to be ready
echo ""
echo "Waiting for Istio control plane to be ready..."
kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s

# Create root certificate for Istio CA
echo ""
echo "Creating root certificate for Istio CA..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca-cert
  namespace: istio-system
spec:
  secretName: cacerts
  duration: 8760h # 1 year
  renewBefore: 720h # 30 days
  commonName: istiod.istio-system.svc
  isCA: true
  usages:
    - digital signature
    - key encipherment
    - cert sign
  dnsNames:
    - istiod.istio-system.svc
    - istiod.istio-system.svc.cluster.local
  issuerRef:
    name: $VENAFI_ISSUER_NAME
    kind: ClusterIssuer
    group: cert-manager.io
EOF

# Wait for certificate to be ready
echo "Waiting for Istio CA certificate to be issued..."
kubectl wait --for=condition=ready certificate/istio-ca-cert -n istio-system --timeout=300s

# Restart istiod to pick up the new certificate
echo ""
echo "Restarting istiod to load Venafi-issued certificate..."
kubectl rollout restart deployment/istiod -n istio-system
kubectl rollout status deployment/istiod -n istio-system --timeout=300s

# Enable automatic sidecar injection for test namespace
echo ""
echo "Setting up test namespace with automatic sidecar injection..."
kubectl create namespace test-app --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace test-app istio-injection=enabled --overwrite

# Verify installation
echo ""
echo "Verifying Istio installation..."
echo ""
echo "Istio system pods:"
kubectl get pods -n istio-system

echo ""
echo "Certificates:"
kubectl get certificates -n istio-system

echo ""
echo "Certificate details:"
kubectl describe certificate istio-ca-cert -n istio-system | grep -A 10 "Status:"

# Check if istioctl can connect
if istioctl version &>/dev/null; then
    echo ""
    echo "Istio version:"
    istioctl version
fi

# Cleanup
rm -f /tmp/istio-venafi-config.yaml

echo ""
echo "Istio with Venafi integration installed successfully!"
echo ""
echo "Key components:"
echo "- Istio control plane with external CA integration"
echo "- Certificate management via Venafi Cloud"
echo "- Automatic certificate rotation"
echo "- Trust domain: $ISTIO_TRUST_DOMAIN"
echo ""
echo "Next steps:"
echo "1. Deploy test applications: ./deploy-test-app.sh"
echo "2. Verify mTLS communication between services"
echo "3. Monitor certificate rotation in Venafi Cloud dashboard"
echo "4. Check the README.md for validation commands"