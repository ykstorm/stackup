# Architecture

## 1. The cluster

`kind create cluster` starts the cluster as one kind node, `stackup-control-plane`, in the laptop's Docker, and Docker publishes the node's ports 80 and 443 on the host's loopback address. That node runs the control plane (API server, scheduler, controller-manager, etcd), Calico, the platform pods (ArgoCD, Argo Rollouts, ingress-nginx, cert-manager, Sealed Secrets, Prometheus, Grafana) and the demo pods in the `app` namespace.

`kind/cluster.yaml` defines one node, a control-plane node that also runs every workload. The node is a Docker container running containerd and the kubelet, so pods are containers inside that container.

The cluster sets `disableDefaultCNI: true`, so kind's own CNI never starts. `scripts/bootstrap.sh` installs Calico through the tigera-operator instead, because Calico enforces both the ingress and the egress half of a NetworkPolicy. The pod subnet is `192.168.0.0/16`, matching `kind/calico/installation.yaml`.

The node publishes ports 80 and 443 to the host (`extraPortMappings`), and ingress-nginx binds them with hostPort. That is how `https://grafana.localtest.me` on the laptop reaches the controller pod. Both mappings set `listenAddress: "127.0.0.1"`, so Docker publishes them on the loopback address only; without it Docker uses `0.0.0.0`, and ArgoCD and Grafana would answer anyone on the laptop's network who sends the right Host header.

The whole stack needs about 6 GB of memory for Docker. Below about 4 GB the controllers crash-loop.

| Namespace | What runs there |
|---|---|
| `app` | The demo Rollout. Enforces the `restricted` Pod Security profile. |
| `argocd` | ArgoCD |
| `argo-rollouts` | Argo Rollouts controller |
| `monitoring` | kube-prometheus-stack (Prometheus, Grafana, kube-state-metrics, node-exporter) |
| `ingress-nginx` | ingress-nginx controller |
| `cert-manager` | cert-manager |
| `kube-system` | Sealed Secrets controller, CoreDNS |
| `tigera-operator`, `calico-system`, `calico-apiserver` | Calico |

## 2. The GitOps tree

ArgoCD polls this repository's `main` branch through the `root` Application, which renders six child Applications: argo-rollouts, cert-manager, demo, ingress-nginx, kube-prometheus-stack and sealed-secrets. The demo Application's workload is a Rollout, run by the Argo Rollouts controller.

`argocd/root-app.yaml` renders `argocd/apps/`, a small Helm chart whose templates are the Applications. Each one syncs automatically with prune and self-heal turned on, so git is the source of truth: a resource removed from git is removed from the cluster, and an edit made with `kubectl` is reverted on the next sync. The children sync in three waves (cert-manager and ingress-nginx; kube-prometheus-stack, argo-rollouts and sealed-secrets; the demo), each wave waiting for the previous one to be Healthy. [gitops.md](gitops.md) lists the source of each child.

`scripts/bootstrap.sh` installs only kind, Calico, the `app` namespace and ArgoCD, plus the demo image on the node; ArgoCD installs everything else. Each component has one owner.

## 3. The canary

1. A developer commits a change, for example a new `image.tag`.
2. ArgoCD polls git every two to three minutes (the pinned chart's 120-second reconciliation timeout plus up to 60 seconds of jitter) and applies the updated Rollout.
3. Argo Rollouts sets the new version's weight to 25% and pauses for 30 seconds.
4. After a further 30-second delay it sends the success-rate query over `[2m]` to Prometheus three times, 30 seconds apart. Each result is the ratio of 2xx responses from the new pods.

       at most one below 0.95: setWeight 50, 75, then 100, 30s pauses between
       two below 0.95: abort, new ReplicaSet scaled down, old version keeps serving

The query, as `helm/demo/templates/analysis-template.yaml` renders it with the default values. Argo Rollouts fills in `<hash>`, the pod-template-hash of the new ReplicaSet, when the analysis starts:

```promql
sum(rate(http_requests_total{service="demo-canary", rollouts_pod_template_hash="<hash>", code=~"2.."}[2m]))
/
sum(rate(http_requests_total{service="demo-canary", rollouts_pod_template_hash="<hash>"}[2m]))
```

It covers only the new pods: `demo-canary` is the Rollout's canary Service, which Argo Rollouts points at the new ReplicaSet, and the hash leaves out samples the Service collected from the stable pods before that switch. Requests still reach every pod through the `demo` Service. [gitops.md](gitops.md) explains the weights, the labels and the failure rule in detail.

## 4. Metrics

The demo app (`apps/demo/server.js`) uses prom-client. Every response increments `http_requests_total{service, method, path, code}`, and `GET /metrics` serves it along with the default Node.js process metrics.

The chart's two ServiceMonitors have the Prometheus operator from kube-prometheus-stack (release `kps`) scrape `/metrics` every 30 seconds: one through the `demo` Service, for every pod, and one through the `demo-canary` Service, which also copies each pod's `rollouts-pod-template-hash` label onto the samples for the canary gate. The operator labels each sample with `service`, the Service it came through, and keeps the app's own `service` label as `exported_service`. Grafana reads from that Prometheus and comes with the chart's standard Kubernetes dashboards. There is no alerting and no log or trace pipeline: the stack collects metrics only.

The demo chart adds one dashboard, `helm/demo/dashboards/canary.json` (uid `stackup-canary`), as a ConfigMap that Grafana's sidecar loads. Its top panel runs the gate's query with one line per pod-template-hash against the 0.95 line, and `make lint` fails if the two drift apart. The other panels show requests by status code, 5xx responses by pod, and ready pods per ReplicaSet (from kube-state-metrics), so a canary step or an abort is visible as one ReplicaSet gaining pods and another losing them.

Prometheus and Grafana use `emptyDir` volumes, so their data does not survive a pod restart or `make down`.

## 5. Security settings

| Area | Setting |
|---|---|
| Pod admission | The `app` namespace enforces, audits and warns on the `restricted` Pod Security profile (`manifests/app/00-namespace.yaml`). |
| Pods | The demo runs as UID 1001 with a read-only root filesystem, no capabilities, no privilege escalation, the `RuntimeDefault` seccomp profile, and no service account token mounted. |
| Network | Calico enforces NetworkPolicy in both directions. In `app`, the demo chart denies all traffic by default and allows DNS, calls to the demo pods from inside the namespace, and connections to them from ingress-nginx and Prometheus (`helm/demo/templates/networkpolicy-*.yaml`). |
| Secrets | The Sealed Secrets controller decrypts SealedSecret resources in the cluster. Its key is created per cluster. |
| TLS | cert-manager issues certificates for each Ingress from the self-signed `selfsigned` ClusterIssuer. |

## 6. What is simplified

- One node and one workload namespace.
- No LoadBalancer. kind does not have one, so ingress uses hostPort.
- No persistence. Nothing survives `make down`.
- Self-signed certificates. Browsers and `curl` need to be told to trust them (`curl -k`).
- No alerting, logs or traces.

## 7. Moving off kind

On a managed cluster (EKS, GKE, AKS) the main changes are:

1. A managed control plane with more than one node.
2. A LoadBalancer Service for ingress-nginx instead of hostPort.
3. An ACME ClusterIssuer (DNS-01) instead of the self-signed one.
4. Persistent volumes for Prometheus and Grafana.
5. A backup of the Sealed Secrets key, so sealed values survive a rebuilt cluster.
6. A traffic router (an ingress controller integration or a service mesh), so canary weights are exact shares of traffic rather than pod counts.
