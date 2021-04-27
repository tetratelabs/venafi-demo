# Venafi Demo
This project demonstrates the simple steps to integrate cert-manager, istio-csr, and Venafi to provide workload certificates for an istio service mesh

# Installation

## Installing on GetIstio
Prior to installing ensure you have kubectl, helm, and getistio CLIs installed.  Additionally, you should already have a provisioned kubernetes cluster.

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
  name: istio-ca-tpp
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
istio-system   istio-ca-tpp   True    30s
```

- Utilize the Venafi Issuer to create an Istio intermediate certificate, which will be used to create a local issuer for Istio workload certificates.
```bash
$ kubectl apply -f getistio/istio-root.yaml
```

- Install the [istio-csr](https://github.com/cert-manager/istio-csr), which allows cert-manager to issue workload certificates for Istio.  `certificate.preserveCertificateRequests` is helpful to debug if the certificate issuing is not working as expected later.  
```bash
$ helm install -n cert-manager cert-manager-istio-csr jetstack/cert-manager-istio-csr --set certificate.preserveCertificateRequests=true 
```

- Lastly, verify that the root istiod certificate has been signed and is in `Ready` state:
```bash
$ kubectl get certificate -A

NAMESPACE      NAME       READY   SECRET       AGE
istio-system   istio-ca   True    istio-ca     73s
istio-system   istiod     True    istiod-tls   15s
```

- We can verify that we see the certificates issued and managed by Venafi.

![alt text](../images/venafi.png "Venafi verification")

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

- We can verify that the workload certificate was issued from the Venafi chain of trust by inspecting the secrets injected into the sidecar using `istioclt`:
```bash
$ getistio istioctl proxy-config secret nginx.default -o json | \
   jq '.dynamicActiveSecrets[1].secret.validationContext.trustedCa.inlineBytes' | \
   tr -d '"' | base64 -d | openssl x509 -text -noout

Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            2f:00:04:19:26:e9:97:fe:50:5e:01:5f:18:00:00:00:04:19:26
    Signature Algorithm: sha256WithRSAEncryption
        Issuer: DC=com, DC=venafidemo, CN=venafidemo-TPP-CA
        Validity
            Not Before: Apr 27 13:52:04 2021 GMT
            Not After : Apr 27 14:02:04 2023 GMT
        Subject: O=cert-manager, O=cluster.local, CN=istio-ca.istio-system.svc.cluster.local
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
                Modulus:
                    00:c3:ac:4f:42:3b:5d:fd:f1:ac:ad:fc:21:7a:1e:
                    cc:dc:bf:66:e6:37:4c:ed:77:19:a1:63:fd:0c:0b:
                    76:58:db:3a:02:2a:bc:c9:6f:a4:14:5f:0b:97:95:
                    1a:c8:03:42:32:05:ea:bf:b7:dd:6d:5a:84:83:79:
                    ed:16:c8:ab:d7:4c:be:1c:e8:06:06:fd:53:9a:9b:
                    cd:0e:90:16:ff:75:cd:01:93:7b:4a:94:78:2f:1a:
                    50:39:87:18:b5:81:cf:7f:2f:db:ad:6b:0b:d4:14:
                    6b:c8:da:88:92:8e:62:b3:84:23:72:7f:ba:da:08:
                    78:cc:78:5e:29:37:10:4f:8d:ac:fd:fb:a7:33:f0:
                    4c:eb:2c:40:0c:25:d7:0a:3d:93:14:9c:ff:ef:27:
                    43:2b:b2:71:77:d3:24:b2:83:6a:ed:5d:b4:e9:61:
                    0d:f3:56:9d:50:a5:5a:af:23:6b:b0:32:79:1d:c6:
                    4a:d1:07:c8:6f:72:0b:a8:ed:65:8e:cb:8c:d5:dc:
                    75:33:9d:80:fd:35:fe:2e:83:45:b0:da:12:a9:bb:
                    be:09:e9:bc:ea:40:9b:39:f2:08:62:2a:df:f3:38:
                    20:8b:66:79:77:8b:49:73:08:d0:59:57:b7:97:ab:
                    cc:38:6b:44:9e:b3:5f:35:28:53:c6:1f:b2:8a:60:
                    97:5b
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Key Usage: critical
                Digital Signature, Certificate Sign, CRL Sign
            X509v3 Subject Key Identifier: 
                84:F1:76:E5:45:40:BB:06:04:29:DA:BD:81:80:8D:00:9A:A4:7D:CD
            X509v3 Authority Key Identifier: 
                keyid:83:75:7A:54:58:18:B8:22:1D:28:77:BE:ED:E5:29:3F:D8:A1:F5:FE

            X509v3 CRL Distribution Points: 

                Full Name:
                  URI:ldap:///CN=venafidemo-TPP-CA,CN=tpp,CN=CDP,CN=Public%20Key%20Services,CN=Services,CN=Configuration,DC=venafidemo,DC=com?certificateRevocationList?base?objectClass=cRLDistributionPoint

            Authority Information Access: 
                CA Issuers - URI:ldap:///CN=venafidemo-TPP-CA,CN=AIA,CN=Public%20Key%20Services,CN=Services,CN=Configuration,DC=venafidemo,DC=com?cACertificate?base?objectClass=certificationAuthority

            1.3.6.1.4.1.311.20.2: 
                .
.S.u.b.C.A
            X509v3 Basic Constraints: critical
                CA:TRUE
    Signature Algorithm: sha256WithRSAEncryption
         24:09:c7:0f:a7:06:c1:e1:d2:b5:2c:99:9f:35:14:b7:22:6c:
         d2:0a:03:63:91:3d:d8:36:bb:7e:11:96:73:73:e5:7c:7f:0a:
         25:56:6b:56:d2:48:dc:10:9e:cf:3f:33:5a:46:52:65:4c:67:
         cf:42:a2:ba:95:e4:27:c3:6c:fa:e9:7c:66:b6:74:43:78:b4:
         29:1b:2e:72:06:33:39:19:ad:a4:4e:7b:83:8d:08:c0:1c:55:
         d2:2a:ba:03:0d:44:fc:6e:26:e3:9b:96:b7:cf:00:1d:36:fe:
         1f:af:a0:90:52:f1:64:b8:54:90:f4:6a:90:28:e9:46:0d:e4:
         6e:5c:77:fe:d5:85:19:b2:ee:b5:02:53:c4:7d:d4:a4:f0:c2:
         92:3e:62:d5:9c:8e:a1:e4:44:1e:bb:bb:c6:05:3b:9e:53:dc:
         98:7c:24:c1:f0:79:c4:f8:bc:45:96:ef:fa:b1:c9:c8:aa:ec:
         21:55:28:0c:e3:81:55:7c:b4:3a:0e:18:a6:fb:be:99:02:33:
         bd:cd:ab:f2:1a:35:88:19:06:4a:2f:55:b1:01:f2:7a:fb:63:
         94:30:88:63:be:04:81:9f:20:d2:4e:2f:1d:00:35:10:7c:15:
         88:bd:ba:04:3f:b8:d6:3e:67:3f:00:16:52:da:75:7c:18:72:
         73:5b:13:74
```
