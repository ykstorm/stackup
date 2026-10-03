# ingress-nginx

The cluster's only ingress controller, installed from the upstream Helm chart with the overrides in [`values.yaml`](./values.yaml), so the install settings are reviewable in git rather than buried in `--set` flags.

`scripts/bootstrap.sh` installs it, and the ArgoCD Application in `argocd/apps/ingress-nginx.yaml` manages it from then on with the same chart and this values file.

## Install or upgrade by hand

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update ingress-nginx

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version 4.15.1 \
  -f infra/ingress-nginx/values.yaml \
  --wait --timeout 5m
```

## How it reaches the laptop

```
laptop:443  --Docker port publish-->  kind node:443  --hostPort-->  ingress-nginx controller pod
                                      (extraPortMappings            (controller.hostPort.enabled=true)
                                       in kind/cluster.yaml)
```

If `https://grafana.localtest.me/` does not reach the controller, check both halves of that path:

1. `docker ps --format '{{.Names}}\t{{.Ports}}' | grep stackup` must show `0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp`. If it does not, the cluster was created without the `extraPortMappings` in `kind/cluster.yaml`; recreate it with `make down && make up`.
2. `kubectl get pods -n ingress-nginx` must show the controller pod `1/1 Running`. If it is `Pending`, another pod holds the host port, usually a stale rollout (see the `Recreate` note below).

## Upgrade strategy

`controller.updateStrategy.type` is `Recreate`, not `RollingUpdate`. Only one pod per node can bind hostPort 80 and 443, so a rolling update would deadlock: the new pod waits for the port while the old pod waits for the new one to become Ready. `Recreate` stops the old pod first. The cost is about five seconds without ingress per upgrade.

## Mutually exclusive flags

`--publish-status-address` and `--publish-service` cannot both be set; the controller exits at startup if they are. The chart enables `publishService` by default, so `values.yaml` turns it off for the `--publish-status-address=localhost` override to take effect. That gives Ingress objects a `.status.loadBalancer.ingress[]` value instead of leaving it empty.
