# GitOps and the canary

ArgoCD reconciles this cluster from git, and the `demo` workload ships through an Argo Rollouts canary. This page describes both.

## App-of-apps

ArgoCD runs in the `argocd` namespace. It is installed from `infra/argocd`, a wrapper chart that pins the upstream `argo/argo-cd` chart. The entry point is one root Application, `argocd/root-app.yaml`, which `make up` applies.

`root` renders `argocd/apps/`, a small Helm chart in this repository. Each of its templates is an Application, one per component, so reconciling `root` brings in the whole tree. The repository URL and revision are values of that chart: the root passes them down, and `scripts/bootstrap.sh` sets both from `STACKUP_REPO` and `STACKUP_REVISION` when they are given, so the tree can follow a fork, a branch or a single commit. The five children:

| Application | Wave | Source | Namespace |
|---|---|---|---|
| `cert-manager` | 0 | `jetstack/cert-manager` v1.20.2 with its CRDs, plus `infra/cert-manager/clusterissuer-selfsigned.yaml` | `cert-manager` |
| `ingress-nginx` | 0 | `ingress-nginx/ingress-nginx` 4.15.1 with `infra/ingress-nginx/values.yaml` | `ingress-nginx` |
| `kube-prometheus-stack` | 1 | `prometheus-community/kube-prometheus-stack` 84.5.0 with `infra/kube-prometheus-stack/values.yaml`, release `kps` | `monitoring` |
| `argo-rollouts` | 1 | `infra/argo-rollouts`, a wrapper chart pinning `argo/argo-rollouts` 2.41.0 | `argo-rollouts` |
| `demo` | 2 | `helm/demo` with `values.dev.yaml` | `app` |

The root and every child run `syncPolicy.automated` with `prune: true` and `selfHeal: true`. A resource deleted from git is pruned from the cluster, and an edit made outside git is reverted on the next sync. Every child also sets:

- `ServerSideApply=true`. Several of these charts ship CRDs larger than the 256 KB annotation a client-side apply writes (`metadata.annotations: Too long`).
- `CreateNamespace=true`.
- A retry policy with backoff, for a sync that fails once because a webhook it needs is still starting.

`cert-manager`, `ingress-nginx` and `kube-prometheus-stack` are multi-source Applications: one source is the pinned upstream chart, the other is this repository, referenced as `$values` for a values file or as a path for the ClusterIssuer. They also ignore the `caBundle` of their admission webhooks, which is filled in after install and never in git. The two wrapper charts (`infra/argo-rollouts`, `infra/argocd`) pin their upstream chart as a dependency in `Chart.yaml`, so one path in this repository renders them.

ArgoCD does not manage itself here. The bootstrap script installs it.

## Bootstrap, then handoff

Each component has one owner. `scripts/bootstrap.sh` (run by `make up`) installs only what has to exist before ArgoCD can work: the kind cluster, Calico, the `app` namespace with its Pod Security labels, and ArgoCD itself. ArgoCD's CRDs come first, applied server-side from the ArgoCD release that matches the chart; the ApplicationSet CRD alone is over 1 MB. The script then builds the demo image and loads it into the node, applies `argocd/root-app.yaml`, and waits until every Application is Synced and Healthy.

Everything else belongs to ArgoCD, in sync waves. Wave 0 is cert-manager and ingress-nginx, whose webhooks the later Ingresses and certificates need. Wave 1 is kube-prometheus-stack and Argo Rollouts. Wave 2 is the demo, which needs the Rollout and ServiceMonitor CRDs from wave 1. Waves of Applications only wait for each other when ArgoCD can tell a child's health, which it stopped doing by default in ArgoCD 1.8; `infra/argocd/values.yaml` adds the health check back. Inside the cert-manager Application, the ClusterIssuer carries its own wave so that it is created after the cert-manager webhook is serving.

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

The `demo` Service spreads requests across all ready pods, so the new version's share of traffic follows its share of pods.

The Rollout also names two Services that carry no traffic, `demo-canary` (`canaryService`) and `demo-stable` (`stableService`). Argo Rollouts adds the `rollouts-pod-template-hash` of one ReplicaSet to their selectors: during an update `demo-canary` selects only the new pods and `demo-stable` only the old ones, and between updates both select the stable pods. The demo Application tells ArgoCD to leave that selector key alone (`ignoreDifferences` with `RespectIgnoreDifferences=true`), since git never has it.

### The analysis gate

The `analysis` step runs the `demo-success-rate` AnalysisTemplate. The Rollout passes it two arguments: `canary-service`, the name of the canary Service (`demo-canary`), and `canary-hash`, the pod-template-hash of the new ReplicaSet (`podTemplateHashValue: Latest`). With the default values the metric is:

| Field | Value |
|---|---|
| Provider | Prometheus at `http://prometheus-operated.monitoring.svc:9090` |
| `initialDelay` | 30s |
| `interval` | 30s |
| `count` | 3 |
| `successCondition` | `result[0] >= 0.95` |
| `failureLimit` | 1 |

The query, with `<hash>` standing for the value of `canary-hash`:

```promql
sum(rate(http_requests_total{service="demo-canary", rollouts_pod_template_hash="<hash>", code=~"2.."}[2m]))
/
sum(rate(http_requests_total{service="demo-canary", rollouts_pod_template_hash="<hash>"}[2m]))
```

Neither `service` nor `rollouts_pod_template_hash` is written by the app; Prometheus adds both when it scrapes:

- The chart has two ServiceMonitors: `demo` scrapes every pod through the `demo` Service, and `demo-canary` scrapes the pods behind the canary Service. The kube-prometheus-stack operator labels each sample with `service`, the name of the Service it was scraped through. The app's own `service` label (`serviceName` in the values) clashes with that label, so Prometheus keeps it as `exported_service`, and the query does not use it.
- The `demo-canary` ServiceMonitor sets `podTargetLabels: [rollouts-pod-template-hash]`, which copies that pod label onto its samples as `rollouts_pod_template_hash`.

The Service name alone would not be enough. Between updates the canary Service selects the stable pods, so for the length of the `[2m]` window after Argo Rollouts switches it, its samples still include the stable pods' traffic. The hash leaves only the new ReplicaSet's samples.

Argo Rollouts fails the metric when the number of failed measurements is greater than `failureLimit`, and marks it successful once `count` measurements are taken without that happening. With three measurements and a limit of one, a single bad reading is tolerated and a second one fails the AnalysisRun. `failureLimit` has to stay below `count`; at or above it, the gate can never fail.

When the AnalysisRun fails, Argo Rollouts aborts the update. It scales the new ReplicaSet down, the old one keeps serving at full size, and the Rollout reports `Degraded`. The next commit, such as a revert, starts a new attempt.

Some details that matter when reading the result:

- The query covers the new pods only, so their error rate is not averaged with the old pods' traffic. A new version that fails more than about 5% of its real requests fails the measurement.
- Every request counts, including kubelet probes and Prometheus scrapes, which always return 200. With no other traffic the ratio is 1.0, so the gate only has something to judge when real requests reach the pods. `ci/traffic.yaml` provides them (see the README's roll-back walk-through). With that traffic the probes and scrapes are a small share, so the threshold sits a little above 5%.
- `rate()` needs two samples of a series. The canary ServiceMonitor scrapes every 30 seconds, so the first measurement, a minute after the canary Service switches, can find only one and return nothing. Argo Rollouts records that as an Error, not a failure, and takes another measurement; an Error does not count towards `count`.

### In CI

`.github/workflows/canary-e2e.yml` runs the same chart on a kind cluster on a GitHub runner, with a single Prometheus (`ci/prometheus.yaml`) that it names `prometheus-operated` so the AnalysisTemplate address does not change. That Prometheus labels its samples the way the chart's two ServiceMonitors do, with `service` and `rollouts_pod_template_hash`, so the gate runs the same query.

The job installs the chart with `helm/demo/values.dev.yaml` and then `helm/demo/values.ci.yaml`. `values.dev.yaml` changes no timing: it turns on the Rollout, the NetworkPolicies and the Ingress, and lowers the resource requests and limits. `values.ci.yaml` shortens the timing, with 10s pauses, a 1-minute `rate()` window, and two measurements 15 seconds apart after a 20-second delay. It also turns the ServiceMonitor, the NetworkPolicies and the Ingress off again, because the CI cluster has no Prometheus operator, no ingress controller and no cert-manager, and its Prometheus is not one of the sources the NetworkPolicies allow. So the e2e does not exercise the NetworkPolicies, the ServiceMonitors or the Ingress. The threshold stays at 0.95, and `failureLimit` is 1 there too, so two failed measurements abort.
