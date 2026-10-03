# argocd

Installs ArgoCD in the `argocd` namespace: the GitOps control plane. Once it is up, `kubectl apply -f argocd/root-app.yaml` registers the app-of-apps root, which reconciles one child `Application` per component (see `argocd/apps/`) against this repository with automated sync, prune and self-heal.

This directory is a self-contained wrapper chart: `Chart.yaml` pins the upstream `argo/argo-cd` chart (`9.5.21`, ArgoCD `v3.4.3`) as a dependency, so `helm lint` runs in CI and the install needs no separate `helm repo add`. ArgoCD does not manage itself; the bootstrap script installs it.

## Install or upgrade by hand

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm dependency build infra/argocd
helm upgrade --install argocd infra/argocd \
  --namespace argocd --create-namespace \
  --wait --timeout 5m

kubectl apply -f argocd/root-app.yaml
```

## Access

The server is at https://argocd.localtest.me. TLS is terminated by the ingress with a certificate from cert-manager's `selfsigned` ClusterIssuer, stored in the `argocd-server-tls` Secret; use `curl -k` for the self-signed chain. The initial admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Why the server runs insecure behind the ingress

The ingress terminates TLS. Running the ArgoCD server in insecure (plain HTTP) mode behind it (`configs.params."server.insecure": true`) avoids a second TLS hop in which the server would present its own certificate under the ingress one.
