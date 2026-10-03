# GitOps and the canary

ArgoCD reconciles this cluster from git, and the `demo` workload ships through an Argo Rollouts canary. This page describes both.

## App-of-apps

ArgoCD runs in the `argocd` namespace. It is installed from `infra/argocd`, a wrapper chart that pins the upstream `argo/argo-cd` chart. The entry point is one root Application:

```sh
kubectl apply -f argocd/root-app.yaml
```

`root` points at `argocd/apps/` in this repository. Every file there is itself an Application, one per component, so reconciling `root` pulls in the whole tree. The six children:

| Application | Source | Namespace |
|---|---|---|
| `argo-rollouts` | `infra/argo-rollouts`, a wrapper chart pinning `argo/argo-rollouts` 2.41.0 | `argo-rollouts` |
| `cert-manager` | `jetstack/cert-manager` v1.20.2 with `installCRDs=true` | `cert-manager` |
| `demo` | `helm/demo` with `values.dev.yaml` | `app` |
| `ingress-nginx` | `ingress-nginx/ingress-nginx` 4.15.1 with `infra/ingress-nginx/values.yaml` | `ingress-nginx` |
| `kube-prometheus-stack` | `prometheus-community/kube-prometheus-stack` 84.5.0 with `infra/kube-prometheus-stack/values.yaml` | `monitoring` |
| `sealed-secrets` | `sealed-secrets` chart 2.18.6 from `bitnami-labs.github.io/sealed-secrets` | `kube-system` |

The root and every child run `syncPolicy.automated` with `prune: true` and `selfHeal: true`. A resource deleted from git is pruned from the cluster, and an edit made outside git is reverted on the next sync.

`ingress-nginx` and `kube-prometheus-stack` are multi-source Applications: one source is the pinned upstream chart, the other is this repository, referenced as `$values` so the chart reads the values file kept here. The two wrapper charts (`infra/argo-rollouts`, `infra/argocd`) pin their upstream chart as a dependency in `Chart.yaml`, so one path in this repository renders them.

ArgoCD does not manage itself here. It is installed once by the bootstrap script.

## Bootstrap, then handoff

`make up` runs `scripts/bootstrap.sh`, which installs the platform charts directly with `helm upgrade --install` and waits for each one. The demo install needs the Rollout and ServiceMonitor CRDs to exist, so the script cannot leave everything to ArgoCD. Its last step applies `argocd/root-app.yaml`. From then on ArgoCD owns the components and reconciles them from `main`. The release names in the script match the ones the Applications render with (`kube-prometheus-stack` sets `releaseName: kps`), so ArgoCD takes over the same objects instead of creating new ones. Sealed Secrets is the exception: the script applies the upstream release manifest, while the Application points at the Helm chart.

## The canary

`helm/demo/values.dev.yaml` sets `rollout.enabled: true`, so the chart renders an Argo `Rollout` and an `AnalysisTemplate` instead of a `Deployment`. Both workload kinds take their container from the same `demo.container` template in `templates/_helpers.tpl`, so they cannot drift apart. The strategy:

```
setWeight 25 -> pause 30s -> analysis -> setWeight 50 -> pause 30s
             -> setWeight 75 -> pause 30s -> setWeight 100
```

Watch a rollout advance:

```sh
make rollout-status
# kubectl argo rollouts get rollout demo -n app --watch
```

There is no traffic router, so Argo Rollouts reaches each weight by pod count. With two replicas and the default surge of one extra pod, it settles on:

| Weight | New pods | Old pods |
|---|---|---|
| 25% | 1 | 2 |
| 50% | 1 | 1 |
| 75% | 2 | 1 |
| 100% | 2 | 0 |

The Service spreads requests across all ready pods, so the new version's share of traffic follows its share of pods.

### The analysis gate

The `analysis` step runs the `demo-success-rate` AnalysisTemplate. The Rollout passes it one argument, `service-name`, set from `serviceName` in the values (`demo`). With the default values the metric is:

| Field | Value |
|---|---|
| Provider | Prometheus at `http://prometheus-operated.monitoring.svc:9090` |
| `initialDelay` | 30s |
| `interval` | 30s |
| `count` | 3 |
| `successCondition` | `result[0] >= 0.95` |
| `failureLimit` | 1 |

The query:

```promql
sum(rate(http_requests_total{service="demo", code=~"2.."}[2m]))
/
sum(rate(http_requests_total{service="demo"}[2m]))
```

Argo Rollouts fails the metric when the number of failed measurements is greater than `failureLimit`, and marks it successful once `count` measurements are taken without that happening. With three measurements and a limit of one, a single bad reading is tolerated and a second one fails the AnalysisRun. `failureLimit` has to stay below `count`; at or above it, the gate can never fail.

When the AnalysisRun fails, Argo Rollouts aborts the update. It scales the new ReplicaSet down, the old one keeps serving at full size, and the Rollout reports `Degraded`. The next commit, such as a revert, starts a new attempt.

Some details that matter when reading the result:

- The query covers every pod behind the Service, old and new. A new version that fails half of its requests while serving a third of the traffic brings the ratio to about 0.83.
- Every request counts, including kubelet probes and Prometheus scrapes, which always return 200. With no other traffic the ratio is 1.0, so the gate only has something to judge when real requests reach the pods. `ci/traffic.yaml` provides them (see the README's roll-back walk-through).
- The `[2m]` window means the first measurement still includes traffic from before the canary started.
- With kube-prometheus-stack, each scraped sample gets a `service` label set to the Kubernetes Service name, and the app's own `service` label is kept as `exported_service`. The release is named `demo`, so both are `demo` and the query matches.

### In CI

`.github/workflows/canary-e2e.yml` runs the same chart on a kind cluster on a GitHub runner, with a single Prometheus (`ci/prometheus.yaml`) that it names `prometheus-operated` so the AnalysisTemplate address does not change. `helm/demo/values.ci.yaml` shortens only the timing: 10s pauses, a 1-minute `rate()` window, two measurements 15 seconds apart after a 20-second delay. The threshold stays at 0.95, and `failureLimit` is 1 there too.
