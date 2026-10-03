# argo-rollouts

Installs the Argo Rollouts controller in the `argo-rollouts` namespace. The controller watches `Rollout` objects and moves the demo through its canary steps, stopping at each `analysis` step to run the `AnalysisTemplate` against Prometheus before it continues.

This directory is a self-contained wrapper chart: `Chart.yaml` pins the upstream `argo/argo-rollouts` chart (`2.41.0`, Argo Rollouts `v1.9.0`) as a dependency, so the ArgoCD Application can point straight at it and `helm lint` runs in CI.

## How it is installed

The `argo-rollouts` Application in `argocd/apps/templates/argo-rollouts.yaml` installs it, in sync wave 1, with server-side apply: the Rollout CRD is larger than the 256 KB annotation a client-side apply writes, which is where `metadata.annotations: Too long` comes from. The kubectl plugin (`make rollout-status`, `make rollout-ui`) should match the controller; `make preflight` prints the install command for `v1.9.0`.

To install it by hand on another cluster:

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm dependency build infra/argo-rollouts
helm upgrade --install argo-rollouts infra/argo-rollouts \
  --namespace argo-rollouts --create-namespace \
  --wait --timeout 5m
```

## Verify

```sh
kubectl get pods -n argo-rollouts
# expect: the argo-rollouts controller pod 1/1 Running

kubectl argo rollouts version
```
