# Venafi Demo
This project demonstrates the simple steps to integrate cert-manager, istio-csr, and Venafi to provide workload certificates for an istio service mesh

# Installation

## Installing on GetIstio
Prior to installing ensure you have kubectl, helm, and getistio CLIs installed.  Addtionally, you should already have a provisioned kubernetes cluster.

- `fetch` your desired Istio version utilizing `getistio fetch`.  You may also list the available version with the `getistio list` command
```bash
$ getistio fetch --version 1.8.4 --flavor tetrate --flavor-version 0

Downloading 1.8.4-tetrate-v0 from https://tetrate.bintray.com/getistio/istio-1.8.4-tetrate-v0-osx.tar.gz ...
Istio 1.8.4 Download Complete!

Istio has been successfully downloaded into your system.

For more information about 1.8.4-tetrate-v0, please refer to the release notes: 
- https://istio.io/latest/news/releases/1.8.x/announcing-1.8.4/

istioctl switched to 1.8.4-tetrate-v0 now
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
$ kubectl apply -f getistio/issuer.yaml
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

- Install Istio using the GetIstio cli using a `IstioOperator` deployment description.  Depending on the version of Istio you are targeting you will need to configure the deployment slightly different.  For Istio v1.7.x, utilize the file `getistio/istio-operator-1.7.yaml`.  For Istio v1.8.x and higher, utilize the file `getistio/istio-operator-1.8.yaml`.  By inspecting the `IstioOperator` yaml descriptor you'll note that a) the Istio CA Server is disabled, b) cert-manager certificates are being mounted into pods, and c) Istio is being direct to call the external address of `cert-manager-istio-csr.cert-manager.svc:443` for certificates.
```bash
$ getistio istioctl install -f getistio/istio-operator-1.8.yaml 

Checking the cluster to make sure it is ready for Istio installation...

#1. Kubernetes-api
-----------------------
Can initialize the Kubernetes client.
Can query the Kubernetes API Server.

#2. Kubernetes-version
-----------------------
Istio is compatible with Kubernetes: v1.18.16-gke.502.

#3. Istio-existence
-----------------------
Istio will be installed in the istio-system namespace.

#4. Kubernetes-setup
-----------------------
Can create necessary Kubernetes configurations: Namespace,ClusterRole,ClusterRoleBinding,CustomResourceDefinition,Role,ServiceAccount,Service,Deployments,ConfigMap. 

#5. SideCar-Injector
-----------------------
This Kubernetes cluster supports automatic sidecar injection. To enable automatic sidecar injection see https://istio.io/v1.8/docs/setup/additional-setup/sidecar-injection/#deploying-an-app

-----------------------
Install Pre-Check passed! The cluster is ready for Istio installation.

This will install the Istio default profile with ["Istio core" "Istiod" "Ingress gateways"] components into the cluster. Proceed? (y/N) y
✔ Istio core installed                                                                                                                                                                    
✔ Istiod installed                                                                                                                                                                        
✔ Ingress gateways installed                                                                                                                                                              
✔ Installation complete 
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
