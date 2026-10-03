# cert-manager

cert-manager plus one self-signed `ClusterIssuer` named `selfsigned`. Every Ingress in the cluster gets its certificate from this issuer.

`scripts/bootstrap.sh` installs the chart and applies the issuer. The ArgoCD Application in `argocd/apps/cert-manager.yaml` manages the chart from then on. The issuer is a cert-manager custom resource applied by the script, not part of that Application.

## Install by hand

```sh
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \
  --set installCRDs=true \
  --wait --timeout 5m

kubectl apply -f infra/cert-manager/clusterissuer-selfsigned.yaml
```

## Why a self-signed issuer

- Let's Encrypt's HTTP-01 challenge needs a public DNS name that reaches the cluster. `*.localtest.me` resolves to 127.0.0.1 everywhere, so the challenge would connect to the CA's own loopback, never to this cluster.
- DNS-01 would work, but it needs an account and an API token with a DNS provider.
- A self-signed issuer gives a working TLS handshake. Browsers and `curl` reject the chain by default; use `curl -k` or accept the browser warning.

## How an Ingress uses it

The Grafana Ingress from `infra/kube-prometheus-stack/values.yaml` is a typical example:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: selfsigned
spec:
  tls:
    - hosts: [grafana.localtest.me]
      secretName: grafana-tls
```

cert-manager sees the annotation, creates a `Certificate` for `grafana-tls`, signs it with the `selfsigned` issuer, and writes the key and certificate into that Secret. ingress-nginx serves it on the TLS handshake.

## Verify

```sh
kubectl get clusterissuer selfsigned \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# expect: True

kubectl get certificate -A
# expect READY True for each Ingress's TLS secret
```
