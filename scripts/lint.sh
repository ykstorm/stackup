#!/usr/bin/env bash
# Static checks for the repository. No cluster is needed. `make lint` runs
# this script, and so does the CI "Static checks" job.
#
#   - every YAML file parses (Helm templates are checked by rendering them)
#   - the shell scripts pass `bash -n` and shellcheck
#   - the Helm charts lint and render, and every render passes kubeconform
#   - the demo chart renders what the cluster expects (Rollout, gate, image,
#     NetworkPolicies, Ingress, ServiceMonitor, dashboard)
#   - the canary dashboard runs the same query as the canary gate
#   - kind/cluster.yaml and the Calico pod CIDR agree
#
# Needs helm, kubeconform and python3 with PyYAML; shellcheck is used when it
# is installed. A missing tool skips its checks with a warning, unless
# LINT_STRICT=1 (set in CI), which turns it into a failure.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

STRICT="${LINT_STRICT:-0}"
SCHEMA_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
KUBECONFORM_CACHE="${TMPDIR:-/tmp}/stackup-kubeconform-cache"
failures=0

section() { printf '\n== %s\n' "$*"; }
ok()      { printf 'ok   %s\n' "$*"; }
warn()    { printf 'warn %s\n' "$*"; }
fail()    { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }
have()    { command -v "$1" >/dev/null 2>&1; }
indent()  { sed 's/^/     /'; }

# missing <tool> <what it is needed for>
missing() {
  if [ "$STRICT" = 1 ]; then
    fail "$1 not found (needed for $2)"
  else
    warn "$1 not found; skipping $2"
  fi
}

# Tracked and new (not ignored) files matching the given pathspecs.
repo_files() { git ls-files --cached --others --exclude-standard -- "$@"; }

# kc <label> [kubeconform flags] [file...]: kubeconform the files, or stdin
# when none are given. Custom resources are checked against the CRDs-catalog
# schemas. Feed stdin with a here-string (kc label <<<"$x"), not a pipe: a
# pipe runs kc in a subshell and its failure count would be lost.
kc() {
  local label="$1" out
  shift
  mkdir -p "$KUBECONFORM_CACHE"
  if out="$(kubeconform -strict -summary -cache "$KUBECONFORM_CACHE" \
      -schema-location default -schema-location "$SCHEMA_CATALOG" "$@" 2>&1)"; then
    ok "$label: ${out##*$'\n'}"
  else
    fail "$label"
    printf '%s\n' "$out" | indent
  fi
}

# count_kind <render> <kind>: number of documents of that kind.
count_kind() { printf '%s\n' "$1" | grep -c "^kind: $2\$" || true; }

# expect_count <label> <render> <kind> <expected>
expect_count() {
  local n
  n="$(count_kind "$2" "$3")"
  if [ "$n" = "$4" ]; then
    ok "$1: $4 $3"
  else
    fail "$1: expected $4 $3, found $n"
  fi
}

# field <render> <key>: first value of "key:" in a render.
field() { printf '%s\n' "$1" | awk -v k="$2:" '$1 == k { gsub(/"/, "", $2); print $2; exit }'; }

have_helm=0;        have helm && have_helm=1
have_kubeconform=0; have kubeconform && have_kubeconform=1
have_python=0;      have python3 && have_python=1

# --------------------------------------------------------------------- #
section "YAML files"
# --------------------------------------------------------------------- #
if [ "$have_python" = 1 ] && python3 -c 'import yaml' 2>/dev/null; then
  yaml_files=()
  while IFS= read -r f; do yaml_files+=("$f"); done \
    < <(repo_files '*.yaml' '*.yml' | grep -v '/templates/')
  if out="$(python3 - "${yaml_files[@]}" <<'PY'
import sys
import yaml

bad = 0
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as fh:
            list(yaml.safe_load_all(fh))
    except Exception as exc:  # report every broken file, not just the first
        print(f"{path}: {exc}")
        bad += 1
sys.exit(1 if bad else 0)
PY
  )"; then
    ok "${#yaml_files[@]} YAML files parse"
  else
    fail "YAML parse errors"
    printf '%s\n' "$out" | indent
  fi
else
  missing "python3 with PyYAML" "the YAML parse check"
fi

# --------------------------------------------------------------------- #
section "Shell scripts"
# --------------------------------------------------------------------- #
scripts=()
while IFS= read -r f; do scripts+=("$f"); done < <(repo_files '*.sh')
syntax_ok=1
for s in "${scripts[@]}"; do
  if ! out="$(bash -n "$s" 2>&1)"; then
    fail "bash -n $s"
    printf '%s\n' "$out" | indent
    syntax_ok=0
  fi
done
[ "$syntax_ok" = 1 ] && ok "bash -n: ${#scripts[@]} scripts"
if have shellcheck; then
  if out="$(shellcheck "${scripts[@]}" 2>&1)"; then
    ok "shellcheck: ${#scripts[@]} scripts"
  else
    fail "shellcheck"
    printf '%s\n' "$out" | indent
  fi
else
  missing shellcheck "the shellcheck pass"
fi

if [ "$have_helm" = 0 ]; then
  missing helm "every chart check"
else
  # ------------------------------------------------------------------- #
  section "Helm charts"
  # ------------------------------------------------------------------- #
  for chart in helm/*/; do
    chart="${chart%/}"
    args=()
    for v in values.dev.yaml values.ci.yaml; do
      [ -f "$chart/$v" ] && args+=(-f "$chart/$v")
    done
    # ${args[@]+...}: an empty array is "unbound" under set -u in bash < 4.4.
    if out="$(helm lint "$chart" 2>&1)" && out="$(helm lint "$chart" ${args[@]+"${args[@]}"} 2>&1)"; then
      ok "helm lint $chart"
    else
      fail "helm lint $chart"
      printf '%s\n' "$out" | indent
    fi
  done

  # The three ways the demo chart is installed: plain defaults, the kind
  # cluster (values.dev.yaml, used by the ArgoCD demo Application) and the
  # CI canary job (values.dev.yaml + values.ci.yaml).
  render() { helm template demo helm/demo -n app "$@" 2>&1; }
  render_default="$(render)"
  render_dev="$(render -f helm/demo/values.dev.yaml)"
  render_ci="$(render -f helm/demo/values.dev.yaml -f helm/demo/values.ci.yaml)"

  if [ "$have_kubeconform" = 1 ]; then
    kc "kubeconform demo (defaults)" <<<"$render_default"
    kc "kubeconform demo (values.dev.yaml)" <<<"$render_dev"
    kc "kubeconform demo (values.dev.yaml + values.ci.yaml)" <<<"$render_ci"
  else
    missing kubeconform "schema validation of the demo chart"
  fi

  # ------------------------------------------------------------------- #
  section "Demo chart contents"
  # ------------------------------------------------------------------- #
  expect_count "defaults" "$render_default" Deployment 1
  expect_count "defaults" "$render_default" Rollout 0
  expect_count "dev" "$render_dev" Rollout 1
  expect_count "dev" "$render_dev" Deployment 0
  expect_count "dev" "$render_dev" AnalysisTemplate 1
  expect_count "dev" "$render_dev" ServiceMonitor 1
  expect_count "dev" "$render_dev" NetworkPolicy 3
  expect_count "dev" "$render_dev" Ingress 1
  expect_count "ci" "$render_ci" Rollout 1
  expect_count "ci" "$render_ci" ServiceMonitor 0
  expect_count "ci" "$render_ci" NetworkPolicy 0
  expect_count "ci" "$render_ci" Ingress 0

  if printf '%s\n' "$render_dev" | grep -q 'grafana_dashboard: "1"'; then
    ok "dev: the canary dashboard ConfigMap carries grafana_dashboard: \"1\""
  else
    fail "dev: no ConfigMap labelled grafana_dashboard: \"1\""
  fi
  if printf '%s\n' "$render_dev" | grep -q 'host: demo.localtest.me'; then
    ok "dev: Ingress host demo.localtest.me"
  else
    fail "dev: Ingress host is not demo.localtest.me"
  fi

  # The gate: Argo Rollouts fails the metric only when failed measurements
  # exceed failureLimit, so failureLimit must stay below count.
  for overlay in dev ci; do
    if [ "$overlay" = dev ]; then
      gate="$(render -f helm/demo/values.dev.yaml --show-only templates/analysis-template.yaml)"
    else
      gate="$(render -f helm/demo/values.dev.yaml -f helm/demo/values.ci.yaml --show-only templates/analysis-template.yaml)"
    fi
    count="$(field "$gate" count)"
    limit="$(field "$gate" failureLimit)"
    if [ -n "$count" ] && [ -n "$limit" ] && [ "$limit" -lt "$count" ]; then
      ok "$overlay: failureLimit $limit is below count $count, so the gate can abort"
    else
      fail "$overlay: failureLimit '${limit}' must be below count '${count}' or the gate can never fail"
    fi
    if printf '%s\n' "$gate" | grep -q 'http_requests_total' \
        && printf '%s\n' "$gate" | grep -q 'successCondition: result\[0\] >= '; then
      ok "$overlay: the gate queries http_requests_total with a result[0] >= threshold"
    else
      fail "$overlay: the AnalysisTemplate no longer queries http_requests_total against a threshold"
    fi
  done

  # The image is built from apps/demo and loaded into kind by bootstrap.sh;
  # it is never pulled, so the pull policy must not be Always.
  workload="$(render -f helm/demo/values.dev.yaml --show-only templates/rollout.yaml)"
  image="$(field "$workload" image)"
  policy="$(field "$workload" imagePullPolicy)"
  case "$image" in
    stackup-demo:*) ok "dev: image $image (built locally and loaded into kind)" ;;
    *) fail "dev: image '$image' is not a local stackup-demo tag" ;;
  esac
  if [ "$policy" = IfNotPresent ]; then
    ok "dev: imagePullPolicy IfNotPresent"
  else
    fail "dev: imagePullPolicy is '$policy'; a side-loaded image needs IfNotPresent"
  fi

  section "Canary dashboard"
  if [ "$have_python" = 1 ]; then
    if out="$(printf '%s\n' "$render_dev" | python3 scripts/check-dashboard-query.py 2>&1)"; then
      ok "the success-rate panel runs the AnalysisTemplate's query"
    else
      fail "the success-rate panel and the AnalysisTemplate query differ"
      printf '%s\n' "$out" | indent
    fi
  else
    missing python3 "the dashboard query check"
  fi

  # ------------------------------------------------------------------- #
  section "Infra wrapper charts"
  # ------------------------------------------------------------------- #
  deps_ready() { compgen -G "$1/charts/*.tgz" >/dev/null; }
  for chart in infra/argo-rollouts infra/argocd; do
    if ! deps_ready "$chart"; then
      if [ "$STRICT" = 1 ]; then
        helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null 2>&1
      fi
      helm dependency build "$chart" >/dev/null 2>&1
    fi
    if ! deps_ready "$chart"; then
      missing "the argo Helm repository (helm repo add argo https://argoproj.github.io/argo-helm)" "$chart"
      continue
    fi
    if out="$(helm lint "$chart" 2>&1)"; then
      ok "helm lint $chart"
    else
      fail "helm lint $chart"
      printf '%s\n' "$out" | indent
    fi
    if [ "$have_kubeconform" = 1 ]; then
      # The upstream CRDs themselves have no schema to check against.
      rendered="$(helm template "$(basename "$chart")" "$chart" -n "$(basename "$chart")" 2>&1)"
      kc "kubeconform $chart" -skip CustomResourceDefinition <<<"$rendered"
    fi
  done
fi

# --------------------------------------------------------------------- #
section "Cluster and raw manifests"
# --------------------------------------------------------------------- #
pod_subnet="$(awk '$1 == "podSubnet:" { print $2 }' kind/cluster.yaml)"
calico_cidr="$(awk '$1 == "cidr:" { print $2 }' kind/calico/installation.yaml)"
if grep -q 'disableDefaultCNI: true' kind/cluster.yaml; then
  ok "kind/cluster.yaml turns off the default CNI (Calico replaces it)"
else
  fail "kind/cluster.yaml must set disableDefaultCNI: true"
fi
if [ -n "$pod_subnet" ] && [ "$pod_subnet" = "$calico_cidr" ]; then
  ok "pod subnet $pod_subnet matches the Calico IP pool"
else
  fail "kind podSubnet '$pod_subnet' and Calico cidr '$calico_cidr' differ"
fi
for port in 80 443; do
  if grep -Eq "containerPort: $port\$" kind/cluster.yaml; then
    ok "kind/cluster.yaml publishes port $port for ingress"
  else
    fail "kind/cluster.yaml does not publish port $port"
  fi
done

if [ "$have_kubeconform" = 1 ]; then
  kc "kubeconform raw manifests" manifests/app/00-namespace.yaml \
    infra/cert-manager/clusterissuer-selfsigned.yaml kind/calico/installation.yaml \
    ci/prometheus.yaml ci/traffic.yaml
  kc "kubeconform ArgoCD Applications" argocd/root-app.yaml argocd/apps/*.yaml
else
  missing kubeconform "schema validation of the raw manifests"
fi

# --------------------------------------------------------------------- #
section "Line endings"
# --------------------------------------------------------------------- #
crlf="$(git ls-files --eol 2>/dev/null | awk '$1 == "i/crlf" { print $NF }')"
if [ -z "$crlf" ]; then
  ok "no file is committed with CRLF line endings"
else
  fail "committed with CRLF line endings: $(printf '%s\n' "$crlf" | tr '\n' ' ')"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
  echo "ok   all static checks passed"
else
  echo "FAIL $failures static check(s) failed"
  exit 1
fi
