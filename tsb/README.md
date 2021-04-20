# Venafi Demo
This project demonstrates the simple steps to integrate cert-manager, istio-csr, and Venafi to provide workload certificates for an istio service mesh

# Installation

## Installing on Tetrate Service Bridge (TSB)
Prior to installing ensure you have kubectl, helm, and Tetate tctl CLIs installed.  Additionally, you should already have a provisioned kubernetes cluster and have an available TSB Management Plane.  These steps assume you are onboarding a cluster named `venafi-test`.  If you are changing the name of you cluster you will need to replace `venafi-test` with your updated cluster name in all commands and yaml files.

```
- Install cert-manager into your cluster
```bash
$ helm repo add jetstack https://charts.jetstack.io
$ helm repo update
$ kubectl create namespace cert-manager
$ helm install -n cert-manager cert-manager jetstack/cert-manager --set installCRDs=true
```

- Create Kubernetes `Secret` for that will be used by the Venafi cert-manager `Issuer`.  If using Venafi Cloud you will configure your API Key.  If using Venafi TPP you will configure either your access token or username/password.  The API call to generate an access token is [/vedauth/authorize](https://venafi-ecosystem-tpp.cld.sr/vedsdk/#/authorize/AuthorizeRoot).  
```bash
$ kubectl create ns istio-system
$ kubectl create secret generic \
   tpp-secret \
   --namespace=istio-system \
   --from-literal=access-token='TOP_SECRET_TOKEN'
```

- Deploy the Venafi `Issuer` for cert-manager.  You will need to update `getistio/issuer.yaml` to contain your correct Venafi Policy Zone and TPP URL.
```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  venafi:
    zone: Venafi Partners\Tetrate # Set this to the Venafi policy zone you want to use
    tpp:
      url: https://venafi-ecosystem-tpp.cld.sr/vedsdk # Change this to the URL of your TPP instance
      credentialsRef:
        name: tpp-secret
```
```bash
$ kubectl apply -f tsb/issuer.yaml
```

- Verify that your cert-manager Issuer for Venafi is in the `Ready` state.
```bash
$ kubectl get issuers.cert-manager.io -A

NAMESPACE      NAME       READY   AGE
istio-system   istio-ca   True    30s
```

- Install the [istio-csr](https://github.com/cert-manager/istio-csr), which allows cert-manager to issue workload certificates for Istio.  `certificate.preserveCertificateRequests` is helpful to debug if the certificate issuing is not working as expected later.  
```bash
$ helm install -n cert-manager cert-manager-istio-csr jetstack/cert-manager-istio-csr --set certificate.preserveCertificateRequests=true 
```

- There is currently an issue that causes the initial certificate issued to Istiod to fail with a message indicating that you must supply a commonName or atleast one subject field:
```bash
$ kubectl get certificate istiod -n istio-system -o json | jq .status                                                                                                    ─╯
{
  "conditions": [
    {
      "lastTransitionTime": "2021-04-19T13:46:29Z",
      "message": "Issuing certificate as Secret does not exist",
      "observedGeneration": 1,
      "reason": "DoesNotExist",
      "status": "False",
      "type": "Ready"
    },
    {
      "lastTransitionTime": "2021-04-19T13:46:31Z",
      "message": "The certificate request has failed to complete and will be retried: Failed to request venafi certificate: Certificate requests submitted to Venafi issuers must have the 'commonName' field or at least one other subject field set.",
      "observedGeneration": 1,
      "reason": "Failed",
      "status": "False",
      "type": "Issuing"
    }
  ],
  "lastFailureTime": "2021-04-19T13:46:31Z"
```

To resolve this you can patch the `Certificate` with the default istio service fqdn of `istiod.istio-system.svc`:
```bash
$ kubectl patch certificate -n istio-system istiod \
   --patch '{"spec":{"commonName":"istiod.istio-system.svc"}}' --type merge
```

- Lastly, verify that the root istiod certificate has been signed and is in `Ready` state:
```bash
$ kubectl get certificate -A

NAMESPACE      NAME     READY   SECRET       AGE
istio-system   istiod   True    istiod-tls   50s
```

- Istio will be lifecycle-managed by TSB.  Prior to onboarding the cluser into TSB you will need to create cluster certs and secrets that will be used to connect securely into the TSB management plane.  Using the tctl CLI generate these files.  ** NOTE ** your kubernetes context must be set to your TSB management cluster when executing these commands:
```bash
$ tctl install manifest control-plane-secrets --cluster venafi-test --allow-defaults > tsb/cluster-secrets.yaml 
$ tctl install cluster-certs --cluster venafi-test > tsb/cluster-certs.yaml  
```

- Change your kubernetes context back to the workload cluster that is being onboarded.  Use `kubectl` to apply the two files that were generated:
```bash
$ kubectl apply -f tsb/cluster-secrets.yaml 
$ kubectl apply -f tsb/cluster-certs.yaml
```

- Generate and apply the TSB Control Plane Operator into your kubernetes cluster.  Replace `$CONTAINER-REGISTRY` with your private container registry that contains your Tetrate images:
```bash
$ tctl install manifest cluster-operator  --registry $CONTAINER-REGISTRY > tsb/cp-operator.yaml 
$ kubectl apply -f tsb/cp-operator.yaml 
```

## Verifying the Integration
- Label a kubernetes namespace with `istio-injection=enabled`
```bash
$ kubectl label ns default istio-injection=enabled --overwrite  
```

- Run a sample pod to verify that istio injects a sidecar container.
```bash
$ kubectl run nginx --image=nginx --namespace default 

$ kubectl get po -n default

NAME    READY   STATUS    RESTARTS   AGE
nginx   2/2     Running   0          22s 
```

- We can verify that we see the certificates issued and managed by Venafi.

![alt text](../images/venafi.png "Venafi verification")
