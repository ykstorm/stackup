.PHONY: up down smoke lint rollout-status demo-image help

KIND_CLUSTER := stackup
HELM_CHART := helm/demo
NAMESPACE := app
DEMO_IMAGE := stackup-demo:v1
ROLLOUT := demo

help:
	@echo "stackup Makefile"
	@echo ""
	@echo "  make up             Full bring-up: scripts/bootstrap.sh (ordered, each step waited)"
	@echo "  make down           Tear down: delete kind cluster (clean)"
	@echo "  make demo-image     Build the demo workload image + side-load it into kind"
	@echo "  make smoke          Run smoke tests (helm render + validate; no cluster needed)"
	@echo "  make lint           Lint all YAML files + Helm charts"
	@echo "  make rollout-status Watch the demo Argo Rollout canary progress"
	@echo ""
	@echo "Prerequisites: docker, kind, helm >=3.15, kubectl, git, bash"

# `up` is a thin wrapper over scripts/bootstrap.sh. The script owns the
# ordering + per-step `kubectl wait` gates (kind -> Calico -> namespace ->
# sealed-secrets -> SealedSecrets -> ingress/cert-manager/prometheus ->
# Argo Rollouts/ArgoCD -> demo workload -> app-of-apps). Keeping the
# orchestration in one place (not split between this target and the
# script) is why the target is a one-liner.
up:
	@bash scripts/bootstrap.sh

# Build + side-load the demo image without a full bring-up. Handy when
# iterating on the workload, or to stage a "bad" image for the rollback
# demo: make demo-image DEMO_IMAGE=stackup-demo:v2 then rebuild with
# --build-arg FAILURE_RATE=0.3 (see apps/demo/Dockerfile).
demo-image:
	docker build -t $(DEMO_IMAGE) apps/demo
	kind load docker-image $(DEMO_IMAGE) --name $(KIND_CLUSTER)

down:
	@echo "=== Deleting kind cluster ==="
	kind delete cluster --name $(KIND_CLUSTER)
	@echo "Cluster deleted. Run 'make up' to bring it back up."

smoke:
	@echo "=== Running smoke tests ==="
	@bash scripts/smoke-test.sh

lint:
	@echo "=== Linting YAML files ==="
	@find . -name "*.yaml" -o -name "*.yml" | grep -v node_modules | while read f; do \
		python3 -c "import yaml; yaml.safe_load(open('$$f'))" 2>/dev/null && echo "ok   $$f" || echo "FAIL $$f: YAML parse error"; \
	done || true

	@echo ""
	@echo "=== Helm lint ==="
	@for chart in helm/demo helm/buyerchat; do \
		helm lint $$chart --quiet && echo "ok   helm lint $$chart" || echo "FAIL helm lint $$chart"; \
		helm template $$(basename $$chart) $$chart > /dev/null 2>&1 && echo "ok   helm template $$chart" || echo "FAIL helm template $$chart"; \
	done

rollout-status:
	kubectl argo rollouts get rollout $(ROLLOUT) -n $(NAMESPACE) --watch
