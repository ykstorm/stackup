#!/usr/bin/env bash
# Serves the cluster's UIs on localhost through kubectl port-forward. kind has
# no LoadBalancer; the *.localtest.me addresses depend on Docker publishing
# ports 80 and 443 of the node, and this is the way in when they do not
# answer. `make port-forward` runs it; Ctrl-C stops every forward.
#
# The ports are the Services' real ones: argocd-server serves plain HTTP on 80
# (the server runs with server.insecure behind the ingress), kps-grafana
# listens on 80, prometheus-operated on 9090 and demo on 3000.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

k get namespace argocd --request-timeout=10s >/dev/null 2>&1 \
  || die "the $STACKUP_CONTEXT cluster does not answer, or has no argocd namespace; run make up first"

# namespace service local-port service-port
FORWARDS=(
  "argocd argocd-server 8080 80"
  "monitoring kps-grafana 3000 80"
  "monitoring prometheus-operated 9090 9090"
  "app demo 8081 3000"
)

trap pf_stop_all EXIT
trap 'exit 130' INT TERM

for f in "${FORWARDS[@]}"; do
  read -r ns svc local_port svc_port <<<"$f"
  pf_start "$ns" "$svc" "$local_port" "$svc_port"
done

failed=0
for f in "${FORWARDS[@]}"; do
  read -r ns svc local_port _ <<<"$f"
  if ! pf_wait "$local_port" 15; then
    printf 'FAIL nothing answers on localhost:%s for svc/%s in %s (is the port taken, or the Service missing?)\n' \
      "$local_port" "$svc" "$ns"
    failed=1
  fi
done
[ "$failed" = 0 ] || exit 1

cat <<'EOF'

  ArgoCD      http://localhost:8080         user admin, password from:
              kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  Grafana     http://localhost:3000         admin / prom-operator
              canary dashboard: http://localhost:3000/d/stackup-canary
  Prometheus  http://localhost:9090
  Demo        http://localhost:8081/metrics

Ctrl-C stops the port-forwards.
EOF

wait
