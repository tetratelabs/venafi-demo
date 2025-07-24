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

### Certificate Issuance Flow

```mermaid
sequenceDiagram
    participant Venafi as Venafi Cloud API
    participant CM as cert-manager Controller
    participant K8s as Kubernetes API
    participant Istiod as istiod (Citadel)
    participant Envoy as Envoy Proxy

    Note over CM: 1. Certificate Creation
    CM->>K8s: Watch Certificate CR<br/>istio-ca in istio-system
    CM->>Venafi: Request CA Certificate<br/>POST /v1/certificaterequests
    Venafi-->>CM: Issue Certificate<br/>CN=istio-ca, CA:TRUE
    CM->>K8s: Create/Update Secret<br/>cacerts in istio-system

    Note over Istiod: 2. CA Loading
    Istiod->>K8s: Watch Secret cacerts<br/>File: /etc/cacerts/*
    K8s-->>Istiod: Mount Secret as Volume
    Istiod->>Istiod: Load root-cert.pem<br/>cert-chain.pem<br/>ca-key.pem

    Note over Envoy: 3. Workload Certificate
    Envoy->>Istiod: CSR via SDS<br/>spiffe://cluster.local/ns/default/sa/httpbin
    Istiod->>Istiod: Generate Certificate<br/>Sign with CA key
    Istiod-->>Envoy: Workload Certificate<br/>Valid: 24h
    Envoy->>Envoy: Store in memory<br/>default cert chain
```

### Certificate Files and Secrets

```mermaid
graph TB
    subgraph "Venafi Cloud"
        VCA[CA Certificate<br/>CN=istio-ca<br/>CA:TRUE<br/>Valid: 90 days]
    end

    subgraph "cert-manager Namespace"
        VSecret[venafi-credentials Secret<br/>━━━━━━━━━━━━━━━<br/>data:<br/>  api-key: base64]
    end

    subgraph "istio-system Namespace"
        CACert[Certificate CR 'istio-ca'<br/>━━━━━━━━━━━━━━━<br/>spec:<br/>  secretName: cacerts<br/>  duration: 2160h<br/>  renewBefore: 360h<br/>  isCA: true]
        
        CASecret[Secret 'cacerts'<br/>━━━━━━━━━━━━━━━<br/>data:<br/>  ca-cert.pem: base64<br/>  ca-key.pem: base64<br/>  cert-chain.pem: base64<br/>  tls.crt: base64<br/>  tls.key: base64]
        
        IstiodPod[istiod Pod<br/>━━━━━━━━━━━━━━━<br/>volumeMounts:<br/>- name: cacerts<br/>  mountPath: /etc/cacerts<br/>  readOnly: true]
    end

    VCA -->|Issues| CACert
    CACert -->|Creates| CASecret
    CASecret -->|Mounts| IstiodPod
```

### mTLS Certificate Chain

```mermaid
graph TD
    subgraph "Certificate Hierarchy"
        Root[Venafi Root CA<br/>Organization Trust Anchor]
        Intermediate[Istio CA Certificate<br/>CN=istio-ca<br/>Issuer: Venafi Root CA<br/>Valid: 90 days]
        Workload[Workload Certificate<br/>URI:spiffe://cluster.local/ns/test/sa/httpbin<br/>Issuer: istio-ca<br/>Valid: 24 hours]
    end

    subgraph "Pod Communication"
        ClientPod[Client Pod<br/>━━━━━━━━━<br/>Envoy Sidecar]
        ServerPod[Server Pod<br/>━━━━━━━━━<br/>Envoy Sidecar]
    end

    Root -->|Signs| Intermediate
    Intermediate -->|Signs| Workload
    ClientPod -->|mTLS Handshake<br/>Present Certificate| ServerPod
    ServerPod -->|Verify Chain<br/>Root → Intermediate → Workload| ServerPod
```

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| cert-manager | v1.18.2 | Certificate lifecycle management |
| Istio | 1.25.2 | Service mesh (auto-reloads certificates) |
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