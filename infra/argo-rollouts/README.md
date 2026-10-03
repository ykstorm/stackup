# argo-rollouts

Installs the Argo Rollouts controller in the `argo-rollouts` namespace. The controller watches `Rollout` objects and moves the demo through its canary steps, stopping at each `analysis` step to run the `AnalysisTemplate` against Prometheus before it continues.

This directory is a self-contained wrapper chart: `Chart.yaml` pins the upstream `argo/argo-rollouts` chart (`2.41.0`) as a dependency, so the ArgoCD Application can point straight at it and `helm lint` runs in CI.

## Install or upgrade by hand

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
