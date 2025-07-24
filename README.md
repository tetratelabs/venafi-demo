# Venafi + Istio CA Rotation

Automated Istio CA certificate lifecycle management using cert-manager and Venafi Cloud.

## Quick Start

```bash
# Prerequisites
export VENAFI_API_KEY="your-api-key"
export VENAFI_ZONE="Your\\Organization\\Project"

# Install
./scripts/install-cert-manager.sh
./scripts/setup-venafi-ca.sh
./scripts/install-istio.sh
./scripts/verify-setup.sh
```

## Architecture

```mermaid
graph LR
    VC[Venafi Cloud] --> CM[cert-manager]
    CM --> Secret[cacerts]
    Secret --> Istiod[istiod/AUTO_RELOAD]
    Istiod --> Workloads[Pods]
```

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| cert-manager | v1.16.2 | Certificate lifecycle management |
| Istio | 1.24.2 | Service mesh with auto-reload |
| Venafi Cloud | Latest | Enterprise certificate authority |

## Configuration

### Venafi Issuer
```yaml
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
```

### Istio CA Certificate
```yaml
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
```

## Certificate Lifecycle

- **Day 0**: Certificate issued (90-day validity)
- **Day 75**: Automatic renewal starts (15 days before expiry)
- **Day 90**: Old certificate expires

## Operations

### Monitor Certificate
```bash
# Status
kubectl get certificate istio-ca -n istio-system

# Expiry date
kubectl get certificate istio-ca -n istio-system -o jsonpath='{.status.notAfter}'

# Force renewal (testing)
kubectl annotate certificate istio-ca -n istio-system \
  cert-manager.io/issue-temporary-certificate="true" --overwrite
```

### Troubleshooting
```bash
# Check issuer
kubectl describe clusterissuer venafi-issuer

# cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Istio certificate reload
kubectl logs -n istio-system deployment/istiod | grep -i cert
```

## Testing

For CI/testing without Venafi:
```bash
./scripts/install-cert-manager.sh
./scripts/setup-self-signed-ca.sh  # Instead of setup-venafi-ca.sh
./scripts/install-istio.sh
./scripts/verify-setup.sh
```

## References

- [Tetrate CA Rotation Blog](https://tetrate.io/blog/automate-istio-ca-rotation-in-production-at-scale)
- [cert-manager Venafi Docs](https://cert-manager.io/docs/configuration/venafi/)
- [Istio Certificate Management](https://istio.io/latest/docs/tasks/security/cert-management/)