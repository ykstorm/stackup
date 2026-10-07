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

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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
  expect_count "defaults" "$render_default" Service 1
  expect_count "dev" "$render_dev" Rollout 1
  expect_count "dev" "$render_dev" Deployment 0
  expect_count "dev" "$render_dev" AnalysisTemplate 1
  # The main Service plus the Rollout's canary and stable Services, and a
  # ServiceMonitor for the main and the canary Service.
  expect_count "dev" "$render_dev" Service 3
  expect_count "dev" "$render_dev" ServiceMonitor 2
  expect_count "dev" "$render_dev" NetworkPolicy 3
  expect_count "dev" "$render_dev" Ingress 1
  expect_count "ci" "$render_ci" Rollout 1
  expect_count "ci" "$render_ci" Service 3
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
    # The gate judges the canary pods alone: the samples scraped through the
    # canary Service that carry the new ReplicaSet's pod-template-hash.
    if [ "$(printf '%s\n' "$gate" | grep -c 'service="{{args.canary-service}}",')" = 2 ] \
        && [ "$(printf '%s\n' "$gate" | grep -c 'rollouts_pod_template_hash="{{args.canary-hash}}"')" = 2 ]; then
      ok "$overlay: the gate selects the canary Service and the canary's pod-template-hash"
    else
      fail "$overlay: the gate's query no longer selects the canary pods alone"
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
  if [ "$(field "$workload" canaryService)" = demo-canary ] \
      && printf '%s\n' "$workload" | grep -q 'podTemplateHashValue: Latest'; then
    ok "dev: the Rollout has a canary Service and passes the canary's pod-template-hash to the gate"
  else
    fail "dev: the Rollout lacks canaryService demo-canary or the canary-hash argument"
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
  section "ArgoCD Applications"
  # ------------------------------------------------------------------- #
  if out="$(helm lint argocd/apps 2>&1)"; then
    ok "helm lint argocd/apps"
  else
    fail "helm lint argocd/apps"
    printf '%s\n' "$out" | indent
  fi
  apps_render="$(helm template root argocd/apps 2>&1)"
  if [ "$have_kubeconform" = 1 ]; then
    kc "kubeconform argocd/apps (rendered)" <<<"$apps_render"
    kc "kubeconform argocd/root-app.yaml" argocd/root-app.yaml
  fi
  expect_count "argocd/apps" "$apps_render" Application 5
  for app in argo-rollouts cert-manager demo ingress-nginx kube-prometheus-stack; do
    if ! printf '%s\n' "$apps_render" | grep -q "^  name: $app\$"; then
      fail "argocd/apps: no Application named $app"
    fi
  done
  ssa="$(printf '%s\n' "$apps_render" | grep -c 'ServerSideApply=true' || true)"
  if [ "$ssa" = 5 ]; then
    ok "argocd/apps: every child uses server-side apply (CRDs over 256 KB)"
  else
    fail "argocd/apps: $ssa of 5 children set ServerSideApply=true"
  fi
  # Pointing the tree at a fork and a revision must change every reference
  # to this repository (bootstrap.sh does this for STACKUP_REPO/REVISION).
  fork_render="$(helm template root argocd/apps --set repoURL=https://example.com/fork.git --set targetRevision=feature 2>&1)"
  fork_refs="$(printf '%s\n' "$fork_render" | grep -c 'targetRevision: feature' || true)"
  if printf '%s\n' "$fork_render" | grep -q 'ykstorm/stackup'; then
    fail "argocd/apps: a child still names ykstorm/stackup when repoURL is overridden"
  elif [ "$fork_refs" = 5 ]; then
    ok "argocd/apps: repoURL and targetRevision reach all 5 sources from this repository"
  else
    fail "argocd/apps: targetRevision override reached $fork_refs of 5 sources"
  fi
  root_repos="$(awk '$1 == "repoURL:" { print $2 }' argocd/root-app.yaml | sort -u)"
  root_revs="$(awk '$1 == "targetRevision:" { print $2 }' argocd/root-app.yaml | sort -u)"
  values_repo="$(awk '$1 == "repoURL:" { print $2 }' argocd/apps/values.yaml)"
  if [ "$(printf '%s\n' "$root_repos" | wc -l | tr -d ' ')" = 1 ] \
      && [ "$(printf '%s\n' "$root_revs" | wc -l | tr -d ' ')" = 1 ] \
      && [ "$root_repos" = "$values_repo" ]; then
    ok "root-app.yaml: its source and the values it passes to the children agree ($root_repos @ $root_revs)"
  else
    fail "root-app.yaml: repoURL/targetRevision differ between its source, its values and argocd/apps/values.yaml"
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
mappings="$(grep -c 'containerPort:' kind/cluster.yaml || true)"
loopback="$(grep -Ec 'listenAddress: "?127\.0\.0\.1"?$' kind/cluster.yaml || true)"
if [ "$mappings" -gt 0 ] && [ "$loopback" = "$mappings" ]; then
  ok "kind/cluster.yaml publishes its $mappings ports on 127.0.0.1 only"
else
  fail "kind/cluster.yaml: $loopback of $mappings port mappings set listenAddress: \"127.0.0.1\"; without it Docker publishes them on every interface"
fi

kind_config="$(awk -F= '$1 == "KIND_CONFIG" { print $2 }' scripts/bootstrap.sh)"
if [ -n "$kind_config" ] && [ -f "$kind_config" ]; then
  ok "bootstrap.sh creates the cluster from $kind_config, which exists"
else
  fail "bootstrap.sh KIND_CONFIG '$kind_config' does not exist"
fi

if [ "$have_kubeconform" = 1 ]; then
  kc "kubeconform raw manifests" manifests/app/00-namespace.yaml \
    infra/cert-manager/clusterissuer-selfsigned.yaml \
    kind/calico/installation.yaml ci/prometheus.yaml ci/traffic.yaml
else
  missing kubeconform "schema validation of the raw manifests"
fi

# --------------------------------------------------------------------- #
section "Pinned versions"
# --------------------------------------------------------------------- #
# app_version <Chart.yaml>: its appVersion with a leading v.
app_version() { awk '$1 == "appVersion:" { gsub(/"/, "", $2); sub(/^v/, "", $2); print "v" $2 }' "$1"; }

argocd_version="$(app_version infra/argocd/Chart.yaml)"
bootstrap_argocd="$(awk -F= '$1 == "ARGOCD_VERSION" { print $2 }' scripts/bootstrap.sh)"
if [ "$argocd_version" = "$bootstrap_argocd" ]; then
  ok "ArgoCD: bootstrap.sh applies the CRDs of $bootstrap_argocd, the chart's appVersion"
else
  fail "ArgoCD: bootstrap.sh ARGOCD_VERSION $bootstrap_argocd differs from infra/argocd appVersion $argocd_version"
fi

# Outside the wrapper chart, Argo Rollouts is pinned in preflight's plugin
# download and in the CI e2e, which installs both the controller and the
# plugin at ARGO_ROLLOUTS_VERSION. Each must equal the version the cluster's
# controller runs, the wrapper chart's appVersion. A missing pin fails too,
# so renaming one cannot turn this check off.
rollouts_version="$(app_version infra/argo-rollouts/Chart.yaml)"
# rollouts_pin <file> <name> <value>
rollouts_pin() {
  if [ -z "$3" ]; then
    fail "Argo Rollouts: no $2 found in $1"
  elif [ "$3" = "$rollouts_version" ]; then
    ok "Argo Rollouts: $1 pins $2 $3, the controller's appVersion"
  else
    fail "Argo Rollouts: $1 pins $2 $3, but infra/argo-rollouts appVersion is $rollouts_version"
  fi
}
rollouts_pin scripts/preflight.sh ROLLOUTS_VERSION \
  "$(awk -F= '$1 == "ROLLOUTS_VERSION" { print $2 }' scripts/preflight.sh)"
rollouts_pin .github/workflows/canary-e2e.yml ARGO_ROLLOUTS_VERSION \
  "$(awk '$1 == "ARGO_ROLLOUTS_VERSION:" { gsub(/"/, "", $2); print $2 }' .github/workflows/canary-e2e.yml)"
# The setup-k8s-tools action can install the plugin too; check any workflow
# that passes it a version.
while IFS= read -r v; do
  rollouts_pin .github rollouts-plugin-version "$v"
done < <(grep -rhoE 'rollouts-plugin-version: *v[0-9.]+' .github 2>/dev/null | grep -oE 'v[0-9.]+$' | sort -u)

# The wrapper charts' appVersion must be the upstream chart's, once the
# dependency has been downloaded.
for chart in infra/argocd infra/argo-rollouts; do
  tgz="$(compgen -G "$chart/charts/*.tgz" | head -n 1)"
  [ -n "$tgz" ] || continue
  # The top-level Chart.yaml only, not a bundled subchart's.
  member="$(tar -tzf "$tgz" 2>/dev/null | grep -E '^[^/]+/Chart\.yaml$' | head -n 1)"
  upstream="$(tar -xzOf "$tgz" "$member" 2>/dev/null | awk '$1 == "appVersion:" { gsub(/"/, "", $2); sub(/^v/, "", $2); print "v" $2; exit }')"
  if [ "$upstream" = "$(app_version "$chart/Chart.yaml")" ]; then
    ok "$chart: appVersion matches the upstream chart ($upstream)"
  else
    fail "$chart: appVersion $(app_version "$chart/Chart.yaml") differs from the upstream chart's $upstream"
  fi
done

# --------------------------------------------------------------------- #
section "Line endings"
# --------------------------------------------------------------------- #
crlf="$(git ls-files --eol 2>/dev/null | awk '$1 == "i/crlf" { print $NF }')"
if [ -z "$crlf" ]; then
  ok "no file is committed with CRLF line endings"
else
  fail "committed with CRLF line endings: $(printf '%s\n' "$crlf" | tr '\n' ' ')"
fi
# A checkout made before .gitattributes existed can still have CRLF scripts.
crlf_scripts="$(git ls-files --eol -- '*.sh' Makefile 2>/dev/null | awk '$2 == "w/crlf" { print $NF }')"
if [ -n "$crlf_scripts" ]; then
  warn "checked out with CRLF line endings, which bash cannot run: $(printf '%s\n' "$crlf_scripts" | tr '\n' ' ')"
  warn "re-clone the repository, or see docs/troubleshooting.md (set: pipefail: invalid option name)"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
  echo "ok   all static checks passed"
else
  echo "FAIL $failures static check(s) failed"
  exit 1
fi
