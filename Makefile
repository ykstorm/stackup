# Stackup. Run make from Linux, macOS, WSL or Git Bash (README, "Windows
# and WSL"). Each target calls a script in scripts/, so everything also works
# without make: ./setup.sh does what `make up` does.

# GNU make for Windows started from PowerShell or cmd has no bash to hand the
# recipes to. Git Bash sets MSYSTEM; WSL does not set OS at all.
ifeq ($(OS),Windows_NT)
ifndef MSYSTEM
$(error Run make from WSL or Git Bash, not from PowerShell or cmd. See "Windows and WSL" in README.md)
endif
endif

# The recipes need bash, and make's default shell is /bin/sh, which is dash on
# Ubuntu and WSL. A make built for Windows (MAKE_HOST Windows32) cannot start
# /bin/bash by that path, so it keeps its own default; the recipes call bash
# by name either way.
ifneq ($(MAKE_HOST),Windows32)
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
endif

KIND_CLUSTER := stackup
NAMESPACE := app
ROLLOUT := demo
DEMO_IMAGE ?= stackup-demo:v1

.PHONY: help up preflight down lint smoke port-forward demo-image rollout-status rollout-ui

help:
	@echo "Stackup"
	@echo ""
	@echo "  make up             Check the prerequisites, then create the cluster and install everything (./setup.sh)"
	@echo "  make preflight      Only check the prerequisites"
	@echo "  make smoke          Check the running cluster: pods, ArgoCD apps, ArgoCD, Grafana, Prometheus, demo"
	@echo "  make port-forward   Reach ArgoCD, Grafana, Prometheus and the demo on localhost ports"
	@echo "  make rollout-status Watch the demo Rollout in the terminal"
	@echo "  make rollout-ui     Argo Rollouts dashboard on http://localhost:3100/rollouts"
	@echo "  make demo-image     Build the demo image and load it into kind (DEMO_IMAGE=stackup-demo:v2)"
	@echo "  make lint           Static checks of the repository, no cluster needed"
	@echo "  make down           Delete the kind cluster"

up:
	@bash setup.sh

preflight:
	@bash scripts/preflight.sh

down:
	kind delete cluster --name $(KIND_CLUSTER)

lint:
	@bash scripts/lint.sh

smoke:
	@bash scripts/smoke.sh

port-forward:
	@bash scripts/port-forward.sh

demo-image:
	docker build -t $(DEMO_IMAGE) apps/demo
	kind load docker-image $(DEMO_IMAGE) --name $(KIND_CLUSTER)

rollout-status:
	kubectl argo rollouts get rollout $(ROLLOUT) -n $(NAMESPACE) --watch

# Served by the kubectl plugin on this machine; it reads Rollouts through the
# current kubeconfig context and runs nothing in the cluster. Ctrl-C stops it.
rollout-ui:
	kubectl argo rollouts dashboard -n $(NAMESPACE)
