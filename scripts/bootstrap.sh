#!/usr/bin/env bash
# Brings the stackup cluster up, one step at a time, each waiting for the last:
#
#   1. the kind cluster from kind/cluster.yaml (kind's own CNI turned off)
#   2. Calico, applied server-side, then the node Ready
#   3. the `app` namespace with the restricted Pod Security profile
#   4. ArgoCD: its CRDs from the matching release (server-side), then the
#      infra/argocd chart
#   5. the demo image, built from apps/demo and loaded into the node
#   6. the app-of-apps root (argocd/root-app.yaml)
#   7. ArgoCD installs everything else from git, in sync waves; this script
#      waits until every Application is Synced and Healthy
#
# Each component has one owner: this script for the first five steps, ArgoCD
# for the rest. Run it through ./setup.sh (make up), which checks the
# prerequisites first. It is safe to run again against an existing cluster.
#
# Environment:
#   STACKUP_REPO          repository ArgoCD syncs from (default: below)
#   STACKUP_REVISION      branch, tag or commit to sync (default: main)
#   STACKUP_APPS_TIMEOUT  seconds to wait for the Applications (default: 1200)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

CLUSTER_NAME=stackup
KIND_CONFIG=kind/cluster.yaml
CALICO_VERSION=v3.28.2
# Keep equal to appVersion in infra/argocd/Chart.yaml (lint.sh checks).
ARGOCD_VERSION=v3.4.3
NAMESPACE=app
DEFAULT_REPO=https://github.com/ykstorm/stackup
REPO_URL="${STACKUP_REPO:-$DEFAULT_REPO}"
REVISION="${STACKUP_REVISION:-main}"
APPS_TIMEOUT="${STACKUP_APPS_TIMEOUT:-1200}"
APPS=(root cert-manager ingress-nginx kube-prometheus-stack argo-rollouts sealed-secrets demo)

# --------------------------------------------------------------------- #
step "1. kind cluster '$CLUSTER_NAME' from $KIND_CONFIG"
# --------------------------------------------------------------------- #
[ -f "$KIND_CONFIG" ] || die "$KIND_CONFIG not found; run this from a full checkout of the repository"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "the cluster already exists; reusing it"
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
  # Earlier versions of this script installed the platform charts with helm
  # directly; ArgoCD would now have to take those objects over.
  if helm status kps -n monitoring >/dev/null 2>&1 || helm status ingress-nginx -n ingress-nginx >/dev/null 2>&1; then
    info "this cluster was created by an older make up that installed the charts with helm;"
    info "if the Applications do not become Healthy, recreate it: make down && make up"
  fi
else
  # No --wait: the node only becomes Ready once Calico runs (step 2).
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# --------------------------------------------------------------------- #
step "2. Calico $CALICO_VERSION"
# --------------------------------------------------------------------- #
# Server-side apply: the operator's CRDs are larger than the 256 KB
# annotation a client-side `kubectl apply` writes, and a re-run is a no-op.
retry 3 10 kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" >/dev/null
kubectl wait --for=condition=Established --timeout=60s \
  crd/installations.operator.tigera.io crd/apiservers.operator.tigera.io
kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=180s
kubectl apply -f kind/calico/installation.yaml >/dev/null
info "waiting for the node to become Ready (it does once Calico runs)"
kubectl wait --for=condition=Ready node --all --timeout=300s

# --------------------------------------------------------------------- #
step "3. namespace '$NAMESPACE' (restricted Pod Security profile)"
# --------------------------------------------------------------------- #
kubectl apply -f manifests/app/00-namespace.yaml >/dev/null

# --------------------------------------------------------------------- #
step "4. ArgoCD $ARGOCD_VERSION"
# --------------------------------------------------------------------- #
# The CRDs come from the ArgoCD release that matches the chart, applied
# server-side before the chart (which has crds.install: false). The
# ApplicationSet CRD is over 1 MB; a client-side apply fails on it, and
# without it the ArgoCD UI shows "Failed to load data".
for crd in application applicationset appproject; do
  retry 3 10 kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/crds/${crd}-crd.yaml" >/dev/null
done
kubectl wait --for=condition=Established --timeout=60s \
  crd/applications.argoproj.io crd/applicationsets.argoproj.io crd/appprojects.argoproj.io

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
retry 3 10 helm dependency build infra/argocd >/dev/null
info "installing the chart and waiting for its pods"
# Two attempts: on a slow connection the first can time out on image pulls.
retry 2 15 helm upgrade --install argocd infra/argocd \
  -n argocd --create-namespace --wait --timeout 10m >/dev/null
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s

# --------------------------------------------------------------------- #
step "5. demo image"
# --------------------------------------------------------------------- #
# The demo Rollout runs a local image with imagePullPolicy IfNotPresent: it is
# built here and loaded into the node, never pulled from a registry. It has
# to be on the node before ArgoCD creates the Rollout in step 7.
image="$(demo_image)"
[ -n "$image" ] || die "could not read the demo image from helm/demo"
node="${CLUSTER_NAME}-control-plane"
docker build -t "$image" apps/demo
kind load docker-image "$image" --name "$CLUSTER_NAME"
docker exec "$node" crictl inspecti "$(node_image_ref "$image")" >/dev/null 2>&1 \
  || die "$image is not on the node after kind load (see docs/troubleshooting.md, ImagePullBackOff)"
info "$image is on the node"

# --------------------------------------------------------------------- #
step "6. app-of-apps root: $REPO_URL at $REVISION"
# --------------------------------------------------------------------- #
root="$(<argocd/root-app.yaml)"
root="${root//"$DEFAULT_REPO"/"$REPO_URL"}"
root="${root//"targetRevision: main"/"targetRevision: $REVISION"}"
kubectl apply -f - <<<"$root" >/dev/null

# --------------------------------------------------------------------- #
step "7. waiting for ArgoCD to sync the Applications (up to $((APPS_TIMEOUT / 60)) minutes)"
# --------------------------------------------------------------------- #
info "wave 0: cert-manager, ingress-nginx; wave 1: kube-prometheus-stack, argo-rollouts, sealed-secrets; wave 2: demo"
info "the first run pulls every image, so this is the slow part"

deadline=$(( $(date +%s) + APPS_TIMEOUT ))
last=""
while :; do
  table="$(app_table)"
  pending=0
  unhealthy=0
  summary=""
  for app in "${APPS[@]}"; do
    state="$(app_state "$table" "$app")"
    summary="$summary $app=$state"
    [ "$state" = "Synced/Healthy" ] || pending=$((pending + 1))
    [ "${state#*/}" = "Healthy" ] || unhealthy=$((unhealthy + 1))
  done
  if [ "$summary" != "$last" ]; then
    info "${summary# }"
    last="$summary"
  fi
  [ "$pending" -eq 0 ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    if [ "$unhealthy" -eq 0 ]; then
      info "every Application is Healthy, but ArgoCD still reports differences from git for some;"
      info "open ArgoCD to see them (make port-forward, then http://localhost:8080)"
      break
    fi
    kubectl get applications.argoproj.io -n argocd || true
    for app in "${APPS[@]}"; do
      msg="$(kubectl get applications.argoproj.io "$app" -n argocd \
        -o jsonpath='{.status.operationState.message}{"\n"}{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null || true)"
      if [ -n "${msg//[[:space:]]/}" ]; then
        printf -- '--- %s\n%s\n' "$app" "$msg"
      fi
    done
    die "the Applications did not become Synced and Healthy in time; see docs/troubleshooting.md"
  fi
  sleep 10
done

kubectl wait --for=jsonpath='{.status.phase}'=Healthy rollout/demo -n "$NAMESPACE" --timeout=300s >/dev/null

# --------------------------------------------------------------------- #
step "done"
# --------------------------------------------------------------------- #
cat <<'EOF'
Open these (localtest.me resolves to 127.0.0.1; the certificates are self-signed):
  ArgoCD            https://argocd.localtest.me   user admin, password from:
                    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  Grafana           https://grafana.localtest.me  admin / prom-operator
  Canary dashboard  https://grafana.localtest.me/d/stackup-canary
  Demo              https://demo.localtest.me

If those addresses do not answer, make port-forward serves the same UIs on localhost.
  make smoke            check that everything is up
  make rollout-status   watch the demo Rollout (make rollout-ui for a web view)
EOF
