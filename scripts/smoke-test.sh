#!/bin/bash
# scripts/smoke-test.sh
# Smoke test: validate helm chart renders and all YAML is schema-conformant.
# Run this after `helm template` to catch errors before cluster apply.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0

log_pass() { echo -e "${GREEN}ok   $1${NC}"; }
log_warn() { echo -e "${YELLOW}warn $1${NC}"; }
log_fail() { echo -e "${RED}FAIL $1${NC}"; ERRORS=$((ERRORS+1)); }

echo "=== stackup smoke test ==="

# 1. Helm lint
echo ""
echo "[1/8] helm lint buyerchat chart..."
if helm lint helm/buyerchat --quiet 2>&1; then
  log_pass "helm lint passed"
else
  log_fail "helm lint failed"
fi

# 2. Helm template + dry-run
echo ""
echo "[2/8] helm template (dry-run)..."
if helm template buyerchat helm/buyerchat --namespace app > /tmp/smoke_manifests.yaml 2>&1; then
  log_pass "helm template succeeded"
else
  log_fail "helm template failed"
fi

# 3. Check required resources in template output
echo ""
echo "[3/8] Required resources present in template..."
for resource in "kind: Deployment" "kind: Service" "kind: Ingress" "kind: NetworkPolicy"; do
  if grep -q "$resource" /tmp/smoke_manifests.yaml; then
    log_pass "$resource found"
  else
    log_fail "$resource NOT found in template output"
  fi
done

# 4. Check no deprecated API versions
echo ""
echo "[4/8] No deprecated APIs (apps/v1beta2, extensions/v1beta1)..."
if grep -E "apps/v1beta2|extensions/v1beta1" /tmp/smoke_manifests.yaml; then
  log_fail "Deprecated API versions found"
else
  log_pass "No deprecated APIs"
fi

# 5. YAML lint on infra files
echo ""
echo "[5/8] YAML lint infra/ and helm/ directories..."
for y in $(find infra helm -name "*.yaml" 2>/dev/null); do
  if ! python3 -c "import yaml; yaml.safe_load(open('$y'))" 2>/dev/null; then
    log_fail "YAML parse error: $y"
  fi
done
if [ $ERRORS -eq 0 ]; then
  log_pass "All YAML files parse correctly"
fi

# 6. Check SealedSecret template is present
echo ""
echo "[6/8] SealedSecret resource present..."
if grep -q "kind: SealedSecret" /tmp/smoke_manifests.yaml; then
  log_pass "SealedSecret found"
else
  log_warn "SealedSecret not found (may be expected in some values combinations)"
fi

# 7. Check ServiceMonitor template
echo ""
echo "[7/8] ServiceMonitor resource present..."
if grep -q "kind: ServiceMonitor" /tmp/smoke_manifests.yaml; then
  log_pass "ServiceMonitor found"
else
  log_warn "ServiceMonitor not found (Prometheus scraping may not be wired)"
fi

# 8. The canary dashboard's success-rate panel must run the gate's query
echo ""
echo "[8/8] Dashboard success-rate query matches the AnalysisTemplate..."
if helm template demo helm/demo -f helm/demo/values.dev.yaml | python3 scripts/check-dashboard-query.py; then
  log_pass "dashboard query matches the canary gate"
else
  log_fail "dashboard query differs from the canary gate"
fi

# Summary
echo ""
echo "=== Summary ==="
if [ $ERRORS -eq 0 ]; then
  log_pass "All smoke tests passed"
  exit 0
else
  log_fail "$ERRORS test(s) failed"
  exit 1
fi