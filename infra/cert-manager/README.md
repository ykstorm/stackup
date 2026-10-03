# cert-manager

cert-manager plus one self-signed `ClusterIssuer` named `selfsigned`. Every Ingress in the cluster gets its certificate from this issuer.

The `cert-manager` Application in `argocd/apps/templates/cert-manager.yaml` installs both, in sync wave 0: the pinned chart with its CRDs (`crds.enabled: true`), and `clusterissuer-selfsigned.yaml` from this directory as a second source. The issuer carries `argocd.argoproj.io/sync-wave: "1"`, so ArgoCD creates it after the chart's Deployments are healthy; before the cert-manager webhook serves, the API server would reject it.

## Install by hand

On a cluster without ArgoCD:

```sh
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \
  --set crds.enabled=true \
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
