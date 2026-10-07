# kube-prometheus-stack

Prometheus, Grafana, kube-state-metrics, node-exporter and the Prometheus operator, as one Helm release (`kps`) in the `monitoring` namespace. The `kube-prometheus-stack` Application in `argocd/apps/templates/kube-prometheus-stack.yaml` installs it with the pinned chart and this values file, in sync wave 1 and with server-side apply, since the operator's CRDs are larger than a client-side apply can store.

## Install by hand

On a cluster without ArgoCD:

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version 84.5.0 \
  -f infra/kube-prometheus-stack/values.yaml \
  --wait --timeout 10m
```

The release name `kps` matters. The demo chart's ServiceMonitors carry `release: kps`, the Grafana Service is `kps-grafana`, and the ArgoCD Application sets `releaseName: kps`.

## Access

| Where | What |
|---|---|
| https://grafana.localtest.me | Grafana. Log in as `admin` / `prom-operator`. |
| `make port-forward`, then http://localhost:3000 | Grafana through `svc/kps-grafana` port 80 |
| `make port-forward`, then http://localhost:9090 | The Prometheus UI (`svc/prometheus-operated` port 9090), including `/targets` |

`prom-operator` is the chart's well-known default password. It is acceptable on a local cluster that holds no real data. Anything shared should set `grafana.admin.existingSecret` to a Secret instead, for example one decrypted by Sealed Secrets.

## Selector override

By default the operator only adopts ServiceMonitor, PodMonitor, PrometheusRule and Probe objects that carry the chart's own release label. `values.yaml` sets the four `*SelectorNilUsesHelmValues` toggles to `false`, so the operator adopts matching objects from any release in any namespace, including the demo chart's two ServiceMonitors.

## Storage

Prometheus and Grafana use `emptyDir` volumes. A pod restart or `make down` loses every metric and any change made in the Grafana UI. Dashboards come back on their own, because Grafana loads them from ConfigMaps labelled `grafana_dashboard: "1"` rather than from its own database. The demo chart ships one of these: the canary dashboard (`helm/demo/dashboards/canary.json`, uid `stackup-canary`). A long-lived install would add `prometheus.prometheusSpec.storageSpec` and `grafana.persistence` backed by a StorageClass.

The default scrape interval is 30 seconds; a ServiceMonitor can override it.

## Four control-plane targets show as down on kind

After install, Prometheus reports these targets as down:

```
kube-controller-manager
kube-etcd
kube-proxy
kube-scheduler
```

kind runs these components bound to localhost, so the chart's ServiceMonitors cannot reach them on their standard ports (10257, 2381, 10249, 10259). Every other target (kubelet, API server, CoreDNS, kube-state-metrics, node-exporter, Grafana, the operator, and Prometheus itself) is up. Setting `kubeControllerManager.enabled`, `kubeEtcd.enabled`, `kubeProxy.enabled` and `kubeScheduler.enabled` to `false` would remove them; they are left on so the gap stays visible.

## Verify

```sh
kubectl get pods -n monitoring                      # all Running
curl -k -i https://grafana.localtest.me             # expect a 302 to /login
kubectl get certificate -n monitoring grafana-tls   # READY True

kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090
# in another shell:
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'
```
