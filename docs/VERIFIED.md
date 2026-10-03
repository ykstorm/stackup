# Live verification — stackup

This page records one run, on 2026-06-24, of the bootstrap as it was then: it installed the platform charts with `helm` and handed them to ArgoCD afterwards. The bootstrap has changed since. It now installs only kind, Calico and ArgoCD, applies the CRDs server-side, and lets ArgoCD install every other component in sync waves. No run of the current version is recorded on this page.

**Date:** 2026-06-24
**Host:** Windows 11 + Docker Desktop (kind v1.35.0 node, 12 vCPU, ~3.7 GB RAM allocated to the Linux engine)
**Scope:** full `make up` bring-up on a clean cluster, then the Argo Rollouts canary end to end.

This is the live counterpart to CI (`ci.yml`), which only static-validates
manifests (`kubeconform -strict`, `helm lint`, `helm template`). At the time CI
did not stand up a cluster, so the canary below had never been exercised before
this run. (Since 2026-07-05, `.github/workflows/canary-e2e.yml` also runs the
canary on a kind cluster in CI.)

## Result: ok, the canary works end to end

A `make down && make up` on a clean kind cluster brought up every platform
component, and the demo Argo Rollouts canary completed a full progressive
delivery with a passing Prometheus analysis gate.

### Platform components (all came up on a clean cluster)

| Component | Evidence |
|---|---|
| kind cluster + Calico CNI (tigera-operator → Installation CR) | node `Ready` |
| `app` namespace (restricted PSS) | applied |
| sealed-secrets controller | `Available` |
| ingress-nginx | `deployed` |
| cert-manager (controller + cainjector + webhook) | 3/3 `Running` |
| kube-prometheus-stack | prometheus-0 `2/2`, operator + kube-state-metrics + node-exporter `Running` |
| argo-rollouts | `deployed`, Rollout CRD + controller `Running` |
| demo workload (Argo Rollout + AnalysisTemplate) | `2/2` Available, `Healthy` |

### Canary progression (captured live)

Triggered a new revision (image `v1` → `v2`) and watched
`kubectl get rollout demo -n app`:

```
step 1  setWeight 25%      → pause
step 2  analysis RUNNING   → AnalysisRun queries the operated Prometheus 3× (~90s)
        measurements: [1] [1] [1]   → all Successful (success-rate 1.0 ≥ 0.95)
step 4  analysis Successful → setWeight 50%
step 5  setWeight 75%
step 6  pause
step 8  Healthy ok          → canary complete, stable promoted, 2/2 Available
```

The AnalysisRun (`demo-…-2-2`) ran the real success-rate query
`sum(rate(http_requests_total{code=~"2.."}[2m])) / sum(rate(http_requests_total[2m]))`
against `prometheus-operated.monitoring.svc:9090`, three times, each returning
`1.0` (the demo app's `/metrics` 2xx traffic from health probes), all clearing
the `≥ 0.95` gate — so the rollout advanced through every weight to 100%.

## Bug found and fixed during verification

The demo Rollout was **`InvalidSpec`** on first apply — zero pods, canary never
ran:

```
AnalysisTemplate demo-success-rate has metric success-rate which runs
indefinitely. Invalid value for count: <nil>
```

The `success-rate` metric had `interval` / `successCondition` / `failureLimit`
but no `count`. An **inline canary-step** analysis metric must terminate; without
`count` Argo Rollouts treats it as indefinite and rejects the whole Rollout spec.
`kubeconform` passes (schema-valid) but doesn't run Argo's semantic validation,
so CI never caught it. Fixed by adding `rollout.analysis.count` (= 3, matching
the README's "three times over 90 seconds") and rendering it into the
AnalysisTemplate. After the fix the Rollout went `Progressing` → `Healthy` as
captured above.

## Environment notes (not code defects)

- **Slow image pulls + 3.7 GB RAM** made a single-shot `make up` flaky on this
  host: `cert-manager-webhook` and the kube-prometheus-stack pods sat in
  `ContainerCreating` (quay.io pulls) past the `helm --wait` timeout, and under
  full load the API server intermittently returned `TLS handshake timeout`.
- **`set -e` + `helm --wait`:** the first chart whose pods aren't Ready before
  the timeout aborts the whole script. Each rerun caches more images and gets
  further; this run took 3 reruns to clear ingress/cert-manager/kps. A bounded
  `--wait` retry (or `|| true` + an ArgoCD-reconcile gate) would remove the sharp
  edge. Tracked as a follow-up; does not affect correctness of the manifests.
- **Recommendation:** give Docker Desktop ≥ 6–8 GB for a clean single-shot
  bring-up, or run the bring-up on a Linux host/CI runner.
