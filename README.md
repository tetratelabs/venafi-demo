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
helm install -n cert-manager cert-manager jetstack/cert-manager --set installCRDs=true
```


## Installing on Tetrate Service Bridge (TSB)
xxxxx