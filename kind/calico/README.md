# Calico CNI for kind

## Why Calico (not kindnet)

kindnet, the CNI that ships with kind, provides pod-to-pod networking, but its NetworkPolicy enforcement is partial; egress rules in particular are not reliably honored. The demo relies on a default-deny policy with explicit allow rules, so it needs a CNI that enforces both directions.

Calico:

- enforces both `Ingress` and `Egress` rules,
- installs through the upstream `tigera-operator` manifest,
- adds about 30 seconds to the first bring-up and two controller pods at steady state.

`kind/cluster.yaml` sets `disableDefaultCNI: true` so kindnet never starts. The node stays `NotReady` until Calico is applied.

## Pinned version

- Calico `v3.28.2`
- tigera-operator manifest: `https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml`

## Files

- `installation.yaml`: the Calico `Installation` and `APIServer` custom resources. The operator reads them and reconciles the data plane. The IP pool matches `podSubnet: 192.168.0.0/16` in `kind/cluster.yaml`.

## Bring-up order (done by `scripts/bootstrap.sh`)

1. Apply the tigera-operator manifest. It deploys the operator into the `tigera-operator` namespace.
2. `kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=180s`. The operator must be ready before it can reconcile the Installation.
3. `kubectl apply -f kind/calico/installation.yaml`. The operator deploys `calico-node` (a DaemonSet), `calico-kube-controllers` and `calico-apiserver`.
4. `kubectl wait --for=condition=Ready node --all --timeout=300s`. The node turns Ready once Calico's data plane is up.

## Verify

```sh
kubectl get pods -A
# expect: tigera-operator/* and calico-system/* Running, no kindnet-*

kubectl get installation default -o jsonpath='{.status.state}'
# expect: Ready
```
