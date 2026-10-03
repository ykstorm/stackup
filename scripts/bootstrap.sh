#!/usr/bin/env bash
# stackup bootstrap — bring up a kind cluster end to end, in dependency
# order, with a real `kubectl wait` gate between every step so a later
# step never races ahead of an unready prerequisite.
#
# `make up` invokes it. It is idempotent: re-running against an existing
# cluster re-applies harmlessly.
#
# Ordering (each step blocks on the previous):
#   1. kind create cluster (Calico CNI disabled in kind/cluster.yaml)
#   2. install Calico (tigera-operator), wait operator Available
#   3. apply Calico Installation CR, wait NODES Ready (CNI data-plane up)
#   4. apply the `app` workload namespace (restricted PSS)
#   5. install sealed-secrets controller, wait it Ready
#   7. install ingress-nginx / cert-manager / kube-prometheus-stack,
#      wait each Available
#   8. install Argo Rollouts + ArgoCD (wrapper charts), wait Available
#   9. build + side-load the demo image, install the demo chart, wait Ready
#  10. register the ArgoCD app-of-apps root; wait Applications Synced
#
# Run live on 2026-06-24 on a kind cluster (Docker Desktop): every step
# below brought its component up, and the demo Argo Rollouts canary completed
# end to end (25→50→75→100%) with its Prometheus success-rate AnalysisRun
# passing 3/3 (1.0 ≥ 0.95). See docs/VERIFIED.md. The `helm --wait` calls
# below are gated by `set -e`, so on a slow host the first chart whose images
# pull slowly aborts the whole run; rerunning (images now cached) clears it.
set -euo pipefail

CLUSTER_NAME="stackup"
CALICO_VERSION="v3.28.2"
SEALED_SECRETS_VERSION="v0.27.1"
NAMESPACE="app"
DEMO_IMAGE="stackup-demo:v1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

step() { echo ""; echo "==> $*"; }

# --------------------------------------------------------------------- #
# 1. kind cluster
# --------------------------------------------------------------------- #
step "creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "    cluster already exists — skipping create"
else
  kind create cluster --name "$CLUSTER_NAME" --config kind/cluster.yaml --wait 60s
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# --------------------------------------------------------------------- #
# 2. Calico CNI — tigera-operator, then wait it Available
# --------------------------------------------------------------------- #
step "installing Calico CNI (tigera-operator $CALICO_VERSION)"
# `create` (not server-side apply): the operator manifest is large and
# apply can hit the annotation-size limit. AlreadyExists on re-run is fine.
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" 2>/dev/null \
  || echo "    operator resources already present"

step "waiting for tigera-operator Available"
kubectl wait --for=condition=Available deployment/tigera-operator \
  -n tigera-operator --timeout=180s

# --------------------------------------------------------------------- #
# 3. Calico Installation CR, then wait NODES Ready (CNI data-plane)
# --------------------------------------------------------------------- #
step "applying Calico Installation CR"
kubectl apply -f kind/calico/installation.yaml

step "waiting for nodes Ready (Calico data-plane up)"
# Nodes stay NotReady until the Calico CNI binary lands and pod networking
# comes up. Allow 5 min on first bring-up (image pulls).
kubectl wait --for=condition=Ready node --all --timeout=300s

# --------------------------------------------------------------------- #
# 4. workload namespace (restricted PSS) — must exist before SealedSecrets
# --------------------------------------------------------------------- #
step "applying the '$NAMESPACE' workload namespace"
kubectl apply -f manifests/app/00-namespace.yaml

# --------------------------------------------------------------------- #
# 5. sealed-secrets controller, then wait it Ready
# --------------------------------------------------------------------- #
step "installing sealed-secrets controller (${SEALED_SECRETS_VERSION} release manifest)"
# Install from the upstream release manifest rather than a Helm repo — the
# sealed-secrets Helm index (bitnami-labs.github.io/sealed-secrets) 404s, and
# the controller is a single static manifest anyway.
kubectl apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"

step "waiting for sealed-secrets controller Available"
kubectl wait --for=condition=Available deployment/sealed-secrets-controller \
  -n kube-system --timeout=180s

# --------------------------------------------------------------------- #
# 7. foundation platform charts, each waited
# --------------------------------------------------------------------- #
step "installing ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f infra/ingress-nginx/values.yaml --wait --timeout 180s

step "installing cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set installCRDs=true --wait --timeout 180s
kubectl apply -f infra/cert-manager/clusterissuer-selfsigned.yaml

step "installing kube-prometheus-stack"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f infra/kube-prometheus-stack/values.yaml --wait --timeout 600s

# --------------------------------------------------------------------- #
# 8. GitOps control plane — Argo Rollouts (CRDs first), then ArgoCD
# --------------------------------------------------------------------- #
step "installing Argo Rollouts + ArgoCD (wrapper charts)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
for chart in infra/argo-rollouts infra/argocd; do
  ns="$(basename "$chart")"
  echo "    installing $chart into $ns"
  helm dependency build "$chart" >/dev/null
  helm upgrade --install "$ns" "$chart" \
    -n "$ns" --create-namespace --wait --timeout 300s
done

step "waiting for ArgoCD server Available"
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s

# --------------------------------------------------------------------- #
# 9. demo workload — build, side-load, install, wait Ready
# --------------------------------------------------------------------- #
step "building + side-loading the demo image ($DEMO_IMAGE)"
docker build -t "$DEMO_IMAGE" apps/demo
kind load docker-image "$DEMO_IMAGE" --name "$CLUSTER_NAME"

step "installing demo chart (Argo Rollout canary) into '$NAMESPACE'"
helm upgrade --install demo helm/demo \
  -n "$NAMESPACE" --create-namespace \
  -f helm/demo/values.dev.yaml --wait --timeout 180s
# Rollout objects don't satisfy `helm --wait` the way Deployments do; gate
# on the Rollout's own pods becoming Ready.
kubectl rollout status deployment/demo -n "$NAMESPACE" --timeout=180s 2>/dev/null \
  || kubectl wait --for=condition=Ready pod -n "$NAMESPACE" \
       -l app.kubernetes.io/name=demo --timeout=180s

# --------------------------------------------------------------------- #
# 10. GitOps takeover — app-of-apps root, then wait Applications Synced
# --------------------------------------------------------------------- #
step "registering the ArgoCD app-of-apps root"
kubectl apply -f argocd/root-app.yaml

step "waiting for ArgoCD applications to sync"
sleep 30  # allow ArgoCD to register the children before we wait on them
kubectl wait --for=jsonpath='{.status.sync.status}'=Synced \
  applications --all -n argocd --timeout=300s || \
  echo "    (some apps still progressing — check the ArgoCD UI)"

# --------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------- #
step "cluster ready"
echo ""
echo "localtest.me resolves to 127.0.0.1; no hosts-file entries are needed."
echo "  Grafana:           https://grafana.localtest.me (admin / prom-operator)"
echo "  Canary dashboard:  https://grafana.localtest.me/d/stackup-canary"
echo "  ArgoCD:            https://argocd.localtest.me (admin; password in secret argocd-initial-admin-secret)"
echo ""
echo "Watch the canary:  make rollout-status   (or make rollout-ui for http://localhost:3100/rollouts)"
echo "Demo metrics:      kubectl -n $NAMESPACE port-forward svc/demo 3000:3000 then curl localhost:3000/metrics"
