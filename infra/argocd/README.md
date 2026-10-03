# argocd

Installs ArgoCD in the `argocd` namespace: the GitOps control plane. Once it is up, `argocd/root-app.yaml` registers the app-of-apps root, which renders `argocd/apps/` into one child `Application` per component and reconciles them against this repository with automated sync, prune and self-heal.

This directory is a self-contained wrapper chart: `Chart.yaml` pins the upstream `argo/argo-cd` chart (`9.5.21`, ArgoCD `v3.4.3`) as a dependency, so `helm lint` runs in CI and the install needs no separate `helm repo add`. ArgoCD does not manage itself; `scripts/bootstrap.sh` installs it.

## What the values change

- `crds.install: false`. The bootstrap applies ArgoCD's CRDs itself, server-side, from the ArgoCD release that matches the chart (`ARGOCD_VERSION` in `scripts/bootstrap.sh`, checked against `appVersion` by `make lint`). The ApplicationSet CRD is over 1 MB, more than a client-side apply can store.
- `global.domain: argocd.localtest.me`, so ArgoCD's own URL is the address it is served on.
- `server.insecure: true` (see below).
- A health check for `Application` resources in `argocd-cm`. ArgoCD stopped assessing the health of Applications by default in 1.8; without it the root's sync waves would not wait for each other.
- Dex and notifications off.

## Install or upgrade by hand

```sh
for crd in application applicationset appproject; do
  kubectl apply --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/crds/${crd}-crd.yaml
done

helm repo add argo https://argoproj.github.io/argo-helm
helm dependency build infra/argocd
helm upgrade --install argocd infra/argocd \
  --namespace argocd --create-namespace \
  --wait --timeout 10m

kubectl apply -f argocd/root-app.yaml
```

## Access

The server is at https://argocd.localtest.me. TLS is terminated by the ingress with a certificate from cert-manager's `selfsigned` ClusterIssuer, stored in the `argocd-server-tls` Secret; use `curl -k` for the self-signed chain. Without the ingress, `make port-forward` serves it on http://localhost:8080. The initial admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Why the server runs insecure behind the ingress

The ingress terminates TLS. Running the ArgoCD server in insecure (plain HTTP) mode behind it (`configs.params."server.insecure": true`) avoids a second TLS hop in which the server would present its own certificate under the ingress one. Both ports of the `argocd-server` Service, 80 and 443, lead to that plain-HTTP port, which is why a port-forward uses port 80 and an `http://` address.
