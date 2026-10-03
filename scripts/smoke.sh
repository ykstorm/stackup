#!/usr/bin/env bash
# Checks the running cluster after `make up`:
#
#   - the node is Ready and every pod in the stack's namespaces is Ready
#   - every ArgoCD Application is Synced and Healthy, and the demo Rollout
#     is Healthy
#   - through port-forwards: ArgoCD and Grafana answer, Grafana has loaded
#     the canary dashboard, Prometheus scrapes the demo, and the demo serves
#     http_requests_total on /metrics
#   - the https://*.localtest.me addresses answer (a warning only: they
#     depend on Docker publishing ports 80 and 443; make port-forward is the
#     way in when they do not)
#
# `make smoke` runs it. It changes nothing in the cluster. The static checks
# of the repository are `make lint`.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

NAMESPACES=(kube-system tigera-operator calico-system argocd argo-rollouts cert-manager ingress-nginx monitoring app)
APPS=(root cert-manager ingress-nginx kube-prometheus-stack argo-rollouts sealed-secrets demo)

failures=0
ok()   { printf 'ok   %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

trap pf_stop_all EXIT

if ! k get --request-timeout=10s nodes >/dev/null 2>&1; then
  fail "the $STACKUP_CONTEXT cluster does not answer; run make up first"
  exit 1
fi

# --------------------------------------------------------------------- #
# Node and pods
# --------------------------------------------------------------------- #
not_ready="$(k get nodes --no-headers | awk '$2 != "Ready" { print $1 }')"
if [ -z "$not_ready" ]; then
  ok "node Ready"
else
  fail "nodes not Ready: $not_ready"
fi

for ns in "${NAMESPACES[@]}"; do
  if ! k get namespace "$ns" >/dev/null 2>&1; then
    fail "namespace $ns does not exist"
    continue
  fi
  pods="$(k get pods -n "$ns" --no-headers \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready' 2>/dev/null)"
  total="$(awk 'NF' <<<"$pods" | wc -l | tr -d ' ')"
  # Pods of completed Jobs are Succeeded; everything else must be Running
  # with every container ready.
  bad="$(awk '$2 == "Succeeded" { next } NF && ($2 != "Running" || $3 ~ /false/) { printf "%s(%s) ", $1, $2 }' <<<"$pods")"
  if [ "$total" -eq 0 ]; then
    fail "$ns: no pods"
  elif [ -z "$bad" ]; then
    ok "$ns: $total pods ready"
  else
    fail "$ns: not ready: $bad"
  fi
done

# --------------------------------------------------------------------- #
# ArgoCD Applications and the demo Rollout
# --------------------------------------------------------------------- #
table="$(app_table)"
for app in "${APPS[@]}"; do
  state="$(app_state "$table" "$app")"
  if [ "$state" = "Synced/Healthy" ]; then
    ok "Application $app: Synced, Healthy"
  else
    fail "Application $app: $state"
  fi
done

phase="$(k get rollout demo -n app -o jsonpath='{.status.phase}' 2>/dev/null)"
if [ "$phase" = Healthy ]; then
  ok "Rollout demo: Healthy"
else
  fail "Rollout demo: ${phase:-not found}"
fi

# --------------------------------------------------------------------- #
# The services, through port-forwards on high local ports
# --------------------------------------------------------------------- #
# get <url> [curl args...]: the response body, or nothing on failure.
get() { curl -fsS --max-time 10 "$@" 2>/dev/null; }

pf_start argocd argocd-server 18080 80
pf_start monitoring kps-grafana 13000 80
pf_start monitoring prometheus-operated 19090 9090
pf_start app demo 13001 3000
for port in 18080 13000 19090 13001; do
  pf_wait "$port" 20 || true
done

if [ "$(get http://127.0.0.1:18080/healthz)" = ok ]; then
  ok "ArgoCD server answers /healthz"
else
  fail "ArgoCD server does not answer on svc/argocd-server port 80"
fi

if get http://127.0.0.1:13000/api/health | grep -q '"database": *"ok"'; then
  ok "Grafana answers /api/health"
else
  fail "Grafana does not answer on svc/kps-grafana port 80"
fi
grafana_password="$(k get secret kps-grafana -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)"
if get -u "admin:${grafana_password}" http://127.0.0.1:13000/api/dashboards/uid/stackup-canary | grep -q '"uid": *"stackup-canary"'; then
  ok "Grafana has loaded the canary dashboard (uid stackup-canary)"
else
  fail "Grafana has no dashboard with uid stackup-canary"
fi

targets="$(get --get --data-urlencode 'query=count(up{namespace="app"} == 1)' http://127.0.0.1:19090/api/v1/query \
  | sed -n 's/.*"value":\[[^,]*,"\([0-9]*\)"\].*/\1/p')"
if [ "${targets:-0}" -ge 1 ] 2>/dev/null; then
  ok "Prometheus scrapes the demo ($targets targets up in namespace app)"
else
  fail "Prometheus has no demo target up in namespace app"
fi

if get http://127.0.0.1:13001/metrics | grep -q '^http_requests_total'; then
  ok "demo serves http_requests_total on /metrics"
else
  fail "demo does not serve http_requests_total on svc/demo port 3000"
fi

pf_stop_all

# --------------------------------------------------------------------- #
# Ingress (warnings only)
# --------------------------------------------------------------------- #
for url in https://argocd.localtest.me/healthz https://grafana.localtest.me/api/health https://demo.localtest.me/healthz; do
  if curl -fsSk --max-time 10 -o /dev/null "$url" 2>/dev/null; then
    ok "$url answers through ingress-nginx"
  else
    warn "$url does not answer; make port-forward gives the same UIs on localhost (docs/troubleshooting.md)"
  fi
done

printf '\n'
if [ "$failures" -gt 0 ]; then
  echo "FAIL $failures check(s) failed"
  exit 1
fi
echo "ok   the cluster is up"
