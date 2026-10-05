# Stackup

Stackup brings up a single-node Kubernetes cluster on a laptop with one command. kind runs the cluster inside Docker, and ArgoCD keeps it in step with this repository. A small demo service ships through an Argo Rollouts canary: each new version starts on a share of the pods while Prometheus checks the service's HTTP success rate, and the rollout either continues to 100% or rolls back on its own.

[![CI](https://github.com/ykstorm/stackup/actions/workflows/ci.yml/badge.svg)](https://github.com/ykstorm/stackup/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Documentation site: [ykstorm.github.io/stackup](https://ykstorm.github.io/stackup/) (built from `docs-site/`).

## What gets installed

| Layer | Component | What it does here |
|---|---|---|
| Cluster | kind | One Kubernetes node running as a Docker container |
| Network | Calico | Pod networking and NetworkPolicy enforcement in both directions (kind's default CNI is turned off) |
| GitOps | ArgoCD | A root Application renders `argocd/apps/`, which defines six child Applications, and syncs them in waves |
| Delivery | Argo Rollouts | Runs the demo's canary steps and its analysis gate |
| Metrics | kube-prometheus-stack | Prometheus and Grafana |
| Ingress | ingress-nginx | Serves `*.localtest.me` on ports 80 and 443 of the host |
| TLS | cert-manager | Issues certificates from a self-signed ClusterIssuer |
| Secrets | Sealed Secrets | Controller that decrypts SealedSecret resources inside the cluster |
| Pod security | Pod Security Admission | The `app` namespace enforces the `restricted` profile |
| Workload | `demo` (`helm/demo`) | Express service that counts every request in `http_requests_total`; the subject of the canary |

The six child Applications are `argo-rollouts`, `cert-manager`, `demo`, `ingress-nginx`, `kube-prometheus-stack` and `sealed-secrets`.

## Prerequisites

- Docker, with at least 6 GB of memory available to it (Docker Desktop: Settings, Resources). Below about 4 GB the controllers crash-loop.
- `kind`, `kubectl`, and `helm` 3.15 or newer.
- The `kubectl-argo-rollouts` plugin, used by `make rollout-status` and `make rollout-ui`.
- `git` and `bash`, plus `make` for the make targets. On Windows, see [Windows, WSL and macOS](#windows-wsl-and-macos).
- Ports 80 and 443 free on the host. The kind node publishes them for ingress.
- Network access to GitHub and the Helm chart repositories. ArgoCD installs the components from there.

`make preflight` checks all of these and prints the install command for anything missing.

## Bring it up

```bash
git clone https://github.com/ykstorm/stackup && cd stackup
make up        # or ./setup.sh
```

`make up` runs `./setup.sh`, which runs `scripts/preflight.sh` and then `scripts/bootstrap.sh`. The bootstrap creates the kind cluster, installs Calico, creates the `app` namespace, installs ArgoCD (its CRDs first), builds the demo image and loads it into the node, and applies `argocd/root-app.yaml`. From there ArgoCD installs the other components from git in three sync waves: cert-manager and ingress-nginx, then kube-prometheus-stack, Argo Rollouts and Sealed Secrets, then the demo. The script waits until every Application is Synced and Healthy, then prints the addresses below.

The first run pulls every image, so it is the slow one. Running `make up` again reuses the cluster.

## Windows, WSL and macOS

The scripts are bash and run the same way on Linux, macOS, WSL and Git Bash.

- Linux and macOS: `make up`.
- Windows: use WSL 2, with Docker Desktop's WSL integration turned on for the distribution or Docker Engine installed inside WSL. Clone the repository into the Linux file system (`~/stackup`, not `/mnt/c/...`), then `make up`. Git Bash with Docker Desktop works too: run `./setup.sh`, because Git for Windows does not include `make`.
- PowerShell and cmd cannot run the scripts; `make` started from either stops with a message saying so.

The `*.localtest.me` addresses need Docker to publish the kind node's ports 80 and 443 on the host. Docker Desktop and Docker Engine on Linux do. With Docker Engine inside WSL, Windows reaches those ports only through WSL's localhost forwarding; `make port-forward` serves the same UIs on localhost ports in every setup.

[docs/troubleshooting.md](docs/troubleshooting.md) lists the errors seen on Windows and WSL and the fix for each.

## Open

Hostnames under `localtest.me` resolve to `127.0.0.1`, so there is nothing to add to a hosts file. Certificates come from a self-signed issuer, so the browser warns once per host.

- Grafana: [https://grafana.localtest.me](https://grafana.localtest.me). Log in as `admin` / `prom-operator` (the chart's default; this cluster holds no real data).
- The canary dashboard: [https://grafana.localtest.me/d/stackup-canary](https://grafana.localtest.me/d/stackup-canary). It ships with the demo chart (`helm/demo/dashboards/canary.json`) and shows the gate's success-rate query against the 0.95 line, requests by status code, 5xx responses by pod, and ready pods per ReplicaSet.
- ArgoCD: [https://argocd.localtest.me](https://argocd.localtest.me). Log in as `admin`; the password is in a Secret:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  ```
- The rollout, in the terminal: `make rollout-status`. In a browser: `make rollout-ui`, which serves the Argo Rollouts dashboard on [http://localhost:3100/rollouts](http://localhost:3100/rollouts) from your machine.
- The demo: [https://demo.localtest.me](https://demo.localtest.me). Its `/metrics` path shows `http_requests_total`:
  ```bash
  curl -k https://demo.localtest.me/metrics
  ```

If those addresses do not answer, `make port-forward` serves the same UIs on localhost: ArgoCD on http://localhost:8080, Grafana on http://localhost:3000, Prometheus on http://localhost:9090 and the demo on http://localhost:8081. `make smoke` checks the whole cluster from the command line.

## Ship a change through the canary

ArgoCD syncs from the repository and branch in `argocd/root-app.yaml`: `ykstorm/stackup`, `main`. To deploy your own changes, fork the repository and point the cluster at the fork:

```bash
STACKUP_REPO=https://github.com/<you>/stackup make up
```

`STACKUP_REVISION` picks a branch, tag or commit instead of `main`. The bootstrap passes both to every child Application.

1. Build the new image and load it into kind:
   ```bash
   make demo-image DEMO_IMAGE=stackup-demo:v2
   ```
2. Set `image.tag: v2` in `helm/demo/values.yaml`, commit, and push to the branch ArgoCD tracks.
3. ArgoCD picks up the commit (it polls every two to three minutes; Refresh in the UI is faster) and updates the Rollout.
4. Watch it:
   ```bash
   make rollout-status   # kubectl argo rollouts get rollout demo -n app --watch
   ```

The steps come from `helm/demo/templates/rollout.yaml`:

```
setWeight 25 -> pause 30s -> analysis -> setWeight 50 -> pause 30s
             -> setWeight 75 -> pause 30s -> setWeight 100
```

There is no traffic router, so a weight is a share of the pods: with two replicas, the 25% step runs one new pod next to the two old ones.

The analysis step runs the AnalysisTemplate in `helm/demo/templates/analysis-template.yaml`. After a 30-second delay it runs this query against Prometheus three times, 30 seconds apart:

```promql
sum(rate(http_requests_total{service="demo", code=~"2.."}[2m]))
/
sum(rate(http_requests_total{service="demo"}[2m]))
```

A measurement passes when the result is at least 0.95. If two of the three fail, the AnalysisRun fails, Argo Rollouts aborts the update, and the old version keeps serving.

### Watch it roll back

On its own the demo only receives probe and scrape requests, and those always return 200. To see the gate fail, send it real traffic and ship a version that fails part of it:

1. Start two curl pods that call `/api/work` in a loop:
   ```bash
   kubectl apply -f ci/traffic.yaml
   ```
2. Set `failureRate: "0.5"` in `helm/demo/values.yaml` (the new pods fail half of their `/api/work` calls), commit, and push.
3. `make rollout-status` shows the AnalysisRun fail and the rollout stop as `Degraded`, with the old pods still serving.

Revert the commit to bring the Rollout back to `Healthy`, and delete the traffic with `kubectl delete -f ci/traffic.yaml`.

### Checked in CI

[`.github/workflows/canary-e2e.yml`](.github/workflows/canary-e2e.yml) creates a kind cluster on a GitHub runner, installs Argo Rollouts and a small Prometheus, sends steady traffic to the demo, then ships a second image and waits for the canary. The job passes only if the rollout reaches `Healthy` and an AnalysisRun succeeded. It then ships a third revision with `FAILURE_RATE=1`, so every canary request answers 500, and passes only if the gate aborts it: the rollout ends `Degraded`, an AnalysisRun `Failed`, the stable ReplicaSet is the one from the healthy run, and the service still answers 200. The CI values file ([`helm/demo/values.ci.yaml`](helm/demo/values.ci.yaml)) shortens the pauses and the `rate()` window so the run fits a runner; the query and the 0.95 threshold are the same. Last successful run: [2026-10-05](https://github.com/ykstorm/stackup/actions/runs/37333680928).

## Architecture

1. ArgoCD picks up a push to `main` on its next poll and syncs `helm/demo`.
2. The Rollout sets the new version's weight to 25% and pauses for 30 seconds.
3. An AnalysisRun queries Prometheus for the success rate three times, 30 seconds apart.

       at most one measurement below 0.95: 50%, 75%, then 100%
       two measurements below 0.95: abort, the old version keeps serving

[docs/architecture.md](docs/architecture.md) covers the cluster, the ArgoCD tree, and the security settings. [docs/gitops.md](docs/gitops.md) covers the app-of-apps layout, the bootstrap, and the canary in detail.

## Makefile targets

```bash
make help            # list targets
make up              # check the prerequisites, create the cluster and install everything (./setup.sh)
make preflight       # only check the prerequisites
make smoke           # check the running cluster: pods, ArgoCD apps, ArgoCD, Grafana, Prometheus, demo
make port-forward    # ArgoCD, Grafana, Prometheus and the demo on localhost ports
make rollout-status  # watch the demo Rollout in the terminal
make rollout-ui      # Argo Rollouts dashboard on http://localhost:3100/rollouts
make demo-image      # build the demo image and load it into kind (DEMO_IMAGE=stackup-demo:v2 for a new tag)
make lint            # static checks: YAML, shell scripts, chart renders against the schemas (no cluster)
make down            # delete the kind cluster
```

Each target runs one script in `scripts/`, so they also work without `make`.

## Troubleshooting

[docs/troubleshooting.md](docs/troubleshooting.md) covers the errors seen so far, Windows and WSL in particular: line endings, the ApplicationSet CRD, `metadata.annotations: Too long`, `ImagePullBackOff` on the demo, unreachable `*.localtest.me` addresses, port-forward ports, and Applications that stay out of sync.

## Limits

- kind has no LoadBalancer. Ingress uses hostPort 80 and 443 on the single node; `make port-forward` is the way in when those ports are not reachable.
- Nothing is persisted. Prometheus and Grafana use `emptyDir`, and `make down` deletes the cluster.
- The Sealed Secrets controller creates a new key for each cluster, so anything sealed against one cluster will not decrypt on the next.
- One node and one workload namespace. More tenants would need more NetworkPolicy and RBAC work.
- The demo is a stand-in for a real service. It exists so the canary has real request metrics to judge.

## License

Apache License 2.0. See [LICENSE](LICENSE).
