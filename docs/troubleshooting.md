# Troubleshooting

Two commands narrow most problems down:

- `make preflight` checks the prerequisites before anything is created and prints the install command for anything missing. `make up` runs it first.
- `make smoke` checks a running cluster: the node, every pod, the ArgoCD Applications, the demo Rollout, and whether ArgoCD, Grafana, Prometheus and the demo answer.

## Windows and WSL

`make up` needs bash, Docker and the Linux command-line tools, so on Windows it runs in one of two places:

- **WSL 2 (recommended).** Use Ubuntu, with Docker Desktop's WSL integration turned on for the distribution (Docker Desktop, Settings, Resources, WSL integration) or Docker Engine installed inside WSL. Clone the repository into the Linux file system, for example `~/stackup`, not under `/mnt/c`, then run `make up`.
- **Git Bash, with Docker Desktop.** Run `./setup.sh`. Git for Windows does not include `make`; `./setup.sh` does the same as `make up`, and the other targets are one script each in `scripts/`.

PowerShell and cmd cannot run the scripts. `make` started from either stops with a message saying so.

Docker Desktop with the WSL 2 backend takes its memory from WSL. If `make preflight` reports less than 6 GB, set it in `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=8GB
```

then run `wsl --shutdown` in PowerShell and start Docker Desktop again.

## Errors and what fixes them

### `set: pipefail: invalid option name` or `$'\r': command not found`

Either the scripts have Windows line endings, or a shell other than bash ran them.

- Git for Windows checks text files out with CRLF line endings by default (`core.autocrlf=true`). A repository cloned on the Windows side and used from WSL then has CRLF scripts, and bash reads `pipefail\r` as an unknown option. The repository's `.gitattributes` keeps LF line endings on every platform, but a clone made before that file existed keeps its CRLF files. Clone again, inside WSL: `cd ~ && git clone https://github.com/ykstorm/stackup`. `make lint` warns about scripts checked out with CRLF.
- `make` runs recipes with `/bin/sh`, which is dash on Ubuntu and WSL, and dash has no `pipefail`. The Makefile sets `SHELL := /bin/bash`, and every target calls a bash script.

### `kind/kind-config.yaml: no such file or directory`

The kind configuration is `kind/cluster.yaml`. There is no `kind-config.yaml` in this repository, and `make up` passes the right file. To create the cluster by hand:

```bash
kind create cluster --name stackup --config kind/cluster.yaml
```

### `Is a directory` while installing kind

kind's install instructions download the binary with `curl -Lo ./kind ...`. In the root of this repository `./kind` is a directory, so the download fails. Download it to a temporary path instead (Linux and WSL, amd64):

```bash
curl -fsSLo /tmp/kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
sudo install -m 0755 /tmp/kind /usr/local/bin/kind
```

`make preflight` prints the right command for your platform.

### ArgoCD shows "Failed to load data" or "the server could not find the requested resource"

The ApplicationSet CRD is missing. It is over 1 MB, and a plain `kubectl apply` stores a copy of each object in an annotation limited to 256 KB, so a client-side apply of ArgoCD's install manifest fails on that CRD and leaves it out. `make up` applies ArgoCD's three CRDs server-side, from the ArgoCD release that matches the chart, and waits for them before it installs ArgoCD. To check and fix an existing cluster:

```bash
kubectl get crd applicationsets.argoproj.io
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/crds/applicationset-crd.yaml
```

### `metadata.annotations: Too long: must have at most 262144 bytes`

The same limit, hit by another large CRD: Argo Rollouts, Calico's operator or the Prometheus operator. Apply such manifests with `kubectl apply --server-side`. In this repository `scripts/bootstrap.sh` applies Calico and the ArgoCD CRDs server-side, and every ArgoCD Application sets `ServerSideApply=true`, so ArgoCD applies the Argo Rollouts and Prometheus operator CRDs the same way.

### `ImagePullBackOff` or `ErrImagePull` on the demo pods

The demo image is built from `apps/demo` and loaded into the kind node; it is not in any registry, and the chart uses `imagePullPolicy: IfNotPresent`. A demo pod reports `ImagePullBackOff` when the tag its Rollout names is not on the node. That happens after setting a new `image.tag` in git without building it, or after loading the image into a different cluster.

- `make up` builds and loads the tag the chart uses before ArgoCD creates the Rollout, and stops if the node does not have it afterwards.
- For a new tag, build and load it before pushing the commit that uses it: `make demo-image DEMO_IMAGE=stackup-demo:v2`.
- To see what the node has: `docker exec stackup-control-plane crictl images | grep stackup-demo`.

### `https://argocd.localtest.me` or `https://grafana.localtest.me` does not connect

kind has no LoadBalancer. The ingress works because the kind node publishes ports 80 and 443 to the host (`extraPortMappings` in `kind/cluster.yaml`) and the ingress-nginx controller binds them on the node with hostPort. Check each part:

1. `docker port stackup-control-plane` lists 80 and 443 on `127.0.0.1`. If it does not, the cluster was created with another configuration; recreate it with `make down && make up`. The addresses answer only on the laptop itself, so they do not connect from another machine.
2. `kubectl get pods -n ingress-nginx` shows the controller `Running`.
3. `kubectl get ingress -A` lists the ArgoCD, Grafana and demo hosts.
4. Nothing else on the host listens on port 80 or 443. `make preflight` checks this before the cluster exists.

With Docker Engine installed inside WSL rather than Docker Desktop, the ports are published inside the WSL virtual machine, and Windows reaches them through WSL's localhost forwarding, which does not always work. `make port-forward` works in every setup.

### Port-forwarding to ArgoCD or Grafana

`make port-forward` forwards each UI to a local port:

| UI | Local address | Service and port |
|---|---|---|
| ArgoCD | http://localhost:8080 | `argocd/argocd-server`, port 80 |
| Grafana | http://localhost:3000 | `monitoring/kps-grafana`, port 80 |
| Prometheus | http://localhost:9090 | `monitoring/prometheus-operated`, port 9090 |
| Demo | http://localhost:8081 | `app/demo`, port 3000 |

The `argocd-server` Service has ports 80 and 443, not 8080. The server runs with `server.insecure` because TLS ends at the ingress, so both ports serve plain HTTP: forward port 80 and open the address with `http://`. Opening a forwarded port with `https://` fails, because nothing behind it speaks TLS.

Grafana answers `origin not allowed` (HTTP 403) when the host name in the browser's `Origin` header differs from the host the request arrived with. Open it under the name you forwarded or routed: `http://localhost:3000` with `make port-forward`, `https://grafana.localtest.me` through the ingress.

### ArgoCD Applications stay `OutOfSync`, `Missing` or `Unknown`

`make up` waits until every Application is Synced and Healthy and prints their states while it waits. The usual causes of a stuck one, and what the repository does about them:

- **The chart cannot be fetched.** An Application whose source returns an error shows `Unknown`. Every upstream chart is pinned to a version, in its Application or in a wrapper chart's `Chart.yaml`, so check that the chart repository answers and still lists that version.
- **The namespace does not exist.** Every Application that installs into its own namespace sets `CreateNamespace=true`.
- **A CRD is not there yet.** The children carry sync waves: cert-manager and ingress-nginx first, then kube-prometheus-stack and argo-rollouts, then the demo. `infra/argocd/values.yaml` adds the health check that makes the root wait for each wave to be Healthy. Every child also retries a failed sync with backoff.
- **Two installers own the same objects.** `make up` installs only kind, Calico and ArgoCD itself; everything else belongs to ArgoCD. A cluster created by an older `make up`, which installed the charts with `helm` and then handed them to ArgoCD, can keep conflicts. Recreate it: `make down && make up`.

To see why one is stuck:

```bash
kubectl get applications -n argocd
kubectl get application <name> -n argocd -o jsonpath='{.status.conditions}'
```

or open ArgoCD (`make port-forward`, then http://localhost:8080) and look at the resources that are not green.

### `too many open files` in kind node logs, or pods restarting without a reason

kind runs every pod inside one container, which can exhaust the host's inotify limits. On Linux and WSL:

```bash
sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
```

`make preflight` warns when the limit is lower.

### `make up` stops while waiting for the Applications

The first run pulls every image, and on a slow connection that can take longer than the default 20 minutes. Run `make up` again: it reuses the cluster and the images already pulled. `STACKUP_APPS_TIMEOUT=2400 make up` waits longer.
