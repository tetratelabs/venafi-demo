# Certificate Rotation Quick Reference

## Certificate Hierarchy and Timing

```mermaid
gantt
    title Certificate Lifecycle Timeline
    dateFormat  X
    axisFormat %d days
    
    section Root CA
    10 Year Validity           :0, 3650
    Renewal Window (30d)       :3620, 30
    
    section Istio CA  
    60 Day Validity            :0, 60
    Renewal Window (15d)       :45, 15
    
    section Workload
    24 Hour Validity           :0, 1
    Renewal (8h)               :0.67, 0.33
```

## Key Configuration Parameters

### cert-manager Certificate Spec

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  # Certificate validity period
  duration: 1440h        # 60 days (60 * 24 hours)
  
  # When to start renewal process
  renewBefore: 360h      # 15 days (15 * 24 hours)
  
  # Renewal happens at: duration - renewBefore
  # In this case: 60 days - 15 days = 45 days after issuance
```

### Istiod Environment Variables

```yaml
env:
  # Enable automatic CA certificate reload
  - name: AUTO_RELOAD_PLUGIN_CERTS
    value: "true"
  
  # How often to check for new certificates
  - name: PILOT_CERT_CHECK_INTERVAL
    value: "1m"  # Default: 5m
```

## Certificate Locations

| Component | Certificate Location | Secret Name | Namespace |
|-----------|---------------------|-------------|-----------|
| Root CA | `/etc/cert-manager/root-ca` | `root-ca-secret` | `cert-manager` |
| Istio CA | `/etc/cacerts` | `cacerts` | `istio-system` |
| Workload | `/etc/certs` | `istio-ca-secret` | `<app-namespace>` |

## Monitoring Commands

```bash
# Check certificate status
kubectl get certificate -A

# View specific certificate details
kubectl describe certificate istio-ca -n istio-system

# Check expiry date
kubectl get secret cacerts -n istio-system -o json | \
  jq -r '.data."ca-cert.pem"' | \
  base64 -d | \
  openssl x509 -enddate -noout

# Monitor renewal events
kubectl get events -n istio-system --field-selector reason=Issuing
```

## Troubleshooting Rotation Issues

### Certificate Not Rotating

1. Check cert-manager logs:
   ```bash
   kubectl logs -n cert-manager deployment/cert-manager
   ```

2. Verify certificate spec:
   ```bash
   kubectl get certificate istio-ca -n istio-system -o yaml
   ```

3. Check renewal status:
   ```bash
   kubectl get certificate istio-ca -n istio-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
   ```

### Istiod Not Detecting New Certificate

1. Verify environment variable:
   ```bash
   kubectl get deployment istiod -n istio-system -o yaml | grep AUTO_RELOAD_PLUGIN_CERTS
   ```

2. Force reload:
   ```bash
   kubectl rollout restart deployment/istiod -n istio-system
   ```

3. Check logs for certificate loading:
   ```bash
   kubectl logs -n istio-system deployment/istiod | grep -i "loaded ca cert"
   ```

## Production Recommendations

| Certificate | Development | Production |
|-------------|-------------|------------|
| Root CA | 10 years | 10-20 years |
| Istio CA | 60 days | 6-12 months |
| Workload | 24 hours | 24-72 hours |

### Renewal Windows

- Set `renewBefore` to at least 20% of `duration`
- For critical systems, use 30% to allow time for troubleshooting
- Monitor renewal metrics and adjust based on your SLAs