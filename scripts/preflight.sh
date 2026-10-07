#!/usr/bin/env bash
# Checks what `make up` needs before anything is created: docker (running,
# with enough memory), kind, kubectl, helm, the kubectl-argo-rollouts plugin,
# git, openssl, and free ports 80 and 443. For anything missing it prints
# the install command for this platform, and it exits non-zero if a
# requirement is not met. ./setup.sh (make up) runs it first; make preflight
# runs only this.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

CLUSTER_NAME=stackup
KIND_VERSION=v0.31.0
# Keep equal to appVersion in infra/argo-rollouts/Chart.yaml (lint.sh checks).
ROLLOUTS_VERSION=v1.9.0
MIN_HELM="3.15"
# Docker Desktop set to 6 GB reports a little less than that as MemTotal.
MIN_MEM_MB=5600

problems=0
ok()   { printf 'ok   %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; problems=$((problems + 1)); }
hint() { local line; for line in "$@"; do printf '       %s\n' "$line"; done; }
have() { command -v "$1" >/dev/null 2>&1; }

platform=linux
case "$(uname -s)" in
  Darwin) platform=macos ;;
  MINGW*|MSYS*|CYGWIN*) platform=gitbash ;;
  Linux) grep -qi microsoft /proc/version 2>/dev/null && platform=wsl ;;
esac
arch=amd64
case "$(uname -m)" in
  aarch64|arm64) arch=arm64 ;;
esac

case "$platform" in
  linux)   ok "platform: Linux ($arch)" ;;
  macos)   ok "platform: macOS ($arch)" ;;
  wsl)     ok "platform: WSL ($arch)" ;;
  gitbash) ok "platform: Git Bash on Windows" ;;
esac

# Install hints. Downloads go to a temporary path and are then installed into
# /usr/local/bin: the repository has a kind/ directory, so the usual
# `curl -Lo ./kind ...` from its root fails with "Is a directory".
install_hint() {
  case "$1:$platform" in
    kind:macos)      hint "brew install kind" ;;
    kind:gitbash)    hint "winget install Kubernetes.kind   (then open a new Git Bash window)" ;;
    kind:*)          hint "curl -fsSLo /tmp/kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch}" \
                          "sudo install -m 0755 /tmp/kind /usr/local/bin/kind" ;;
    kubectl:macos)   hint "brew install kubectl" ;;
    kubectl:gitbash) hint "winget install Kubernetes.kubectl" ;;
    kubectl:*)       hint "curl -fsSLo /tmp/kubectl \"https://dl.k8s.io/release/\$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl\"" \
                          "sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl" ;;
    helm:macos)      hint "brew install helm" ;;
    helm:gitbash)    hint "winget install Helm.Helm" ;;
    helm:*)          hint "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" ;;
    rollouts:macos)  hint "brew install argoproj/tap/kubectl-argo-rollouts" ;;
    rollouts:gitbash) hint "mkdir -p ~/bin" \
                          "curl -fsSLo ~/bin/kubectl-argo-rollouts.exe https://github.com/argoproj/argo-rollouts/releases/download/${ROLLOUTS_VERSION}/kubectl-argo-rollouts-windows-amd64" ;;
    rollouts:*)      hint "curl -fsSLo /tmp/kubectl-argo-rollouts https://github.com/argoproj/argo-rollouts/releases/download/${ROLLOUTS_VERSION}/kubectl-argo-rollouts-linux-${arch}" \
                          "sudo install -m 0755 /tmp/kubectl-argo-rollouts /usr/local/bin/kubectl-argo-rollouts" ;;
    git:macos)       hint "xcode-select --install   (or: brew install git)" ;;
    git:*)           hint "sudo apt-get install -y git   (or your distribution's package manager)" ;;
    openssl:macos)   hint "brew install openssl" ;;
    openssl:gitbash) hint "Git for Windows ships openssl; reinstall it from https://git-scm.com/download/win" ;;
    openssl:*)       hint "sudo apt-get install -y openssl   (or your distribution's package manager)" ;;
    docker:wsl)      hint "Install Docker Desktop for Windows and turn on Settings > Resources > WSL integration for this distribution," \
                          "or install Docker Engine inside WSL: https://docs.docker.com/engine/install/ubuntu/" ;;
    docker:gitbash)  hint "Install Docker Desktop for Windows: https://docs.docker.com/desktop/setup/install/windows-install/" ;;
    docker:macos)    hint "Install Docker Desktop (https://docs.docker.com/desktop/setup/install/mac-install/) or another engine such as colima" ;;
    docker:*)        hint "Install Docker Engine: https://docs.docker.com/engine/install/" ;;
  esac
}

# --------------------------------------------------------------------- #
# Docker: installed, running, enough memory
# --------------------------------------------------------------------- #
docker_ok=0
if ! have docker; then
  fail "docker not found"
  install_hint docker
elif ! docker info >/dev/null 2>&1; then
  fail "docker is installed but the Docker daemon does not answer"
  case "$platform" in
    wsl)     hint "Start Docker Desktop and check Settings > Resources > WSL integration for this distribution," \
                  "or, with Docker Engine inside WSL: sudo service docker start" ;;
    linux)   hint "sudo systemctl start docker" \
                  "To run docker without sudo: sudo usermod -aG docker \"\$USER\", then log out and back in." ;;
    *)       hint "Start Docker Desktop and wait until it reports that the engine is running." ;;
  esac
else
  docker_ok=1
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null)"
  case "$mem_bytes" in
    ''|*[!0-9]*) mem_bytes=0 ;;
  esac
  mem_mb=$(( mem_bytes / 1024 / 1024 ))
  mem_gb="$(awk -v m="$mem_mb" 'BEGIN { printf "%.1f", m / 1024 }')"
  if [ "$mem_mb" -ge "$MIN_MEM_MB" ]; then
    ok "docker is running with $mem_gb GB of memory"
  else
    fail "docker has $mem_gb GB of memory; the cluster needs about 6 GB"
    case "$platform" in
      wsl|gitbash) hint "Docker Desktop on WSL 2 gets its memory from WSL. In %UserProfile%\\.wslconfig set:" \
                        "  [wsl2]" "  memory=8GB" \
                        "then run 'wsl --shutdown' in PowerShell and start Docker Desktop again." ;;
      macos)       hint "Docker Desktop: Settings > Resources > Memory, at least 6 GB." ;;
      *)           hint "Docker uses this machine's memory; close other workloads or use a machine with more." ;;
    esac
  fi
fi

# --------------------------------------------------------------------- #
# Command-line tools
# --------------------------------------------------------------------- #
if have kind; then
  ok "kind: $(kind version 2>/dev/null | awk '{ print $2 }')"
else
  fail "kind not found"
  install_hint kind
fi

if have kubectl; then
  ok "kubectl: $(kubectl version --client 2>/dev/null | awk -F': ' '/Client Version/ { print $2 }')"
else
  fail "kubectl not found"
  install_hint kubectl
fi

# at_least <version like v3.15.2> <minimum like 3.15>
at_least() {
  local v="${1#v}" major minor want_major="${2%%.*}" want_minor="${2#*.}"
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%.*}"
  case "$major$minor" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$major" -gt "$want_major" ] || { [ "$major" -eq "$want_major" ] && [ "$minor" -ge "$want_minor" ]; }
}

if have helm; then
  helm_version="$(helm version --template '{{.Version}}' 2>/dev/null)"
  if at_least "$helm_version" "$MIN_HELM"; then
    ok "helm: $helm_version"
  else
    fail "helm $helm_version is older than $MIN_HELM"
    install_hint helm
  fi
else
  fail "helm not found"
  install_hint helm
fi

if have kubectl-argo-rollouts; then
  ok "$(kubectl-argo-rollouts version 2>/dev/null | head -n 1)"
else
  fail "the kubectl-argo-rollouts plugin was not found (make rollout-status and make rollout-ui use it)"
  install_hint rollouts
fi

if have git; then
  ok "git: $(git --version | awk '{ print $3 }')"
else
  fail "git not found"
  install_hint git
fi

# The bootstrap generates Grafana's admin password with openssl rand.
if have openssl; then
  ok "openssl: $(openssl version | awk '{ print $1, $2 }')"
else
  fail "openssl not found (make up generates Grafana's admin password with it)"
  install_hint openssl
fi

if ! have curl; then
  warn "curl not found; make smoke and make port-forward use it to check the services"
fi
if ! have make; then
  case "$platform" in
    gitbash) warn "make not found; Git for Windows does not include it. ./setup.sh does what make up does." ;;
    *)       warn "make not found; ./setup.sh does what make up does." ;;
  esac
fi

# --------------------------------------------------------------------- #
# Ports 80 and 443, unless the cluster already holds them
# --------------------------------------------------------------------- #
cluster_exists=0
if have kind && [ "$docker_ok" = 1 ] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  cluster_exists=1
  ok "the '$CLUSTER_NAME' kind cluster already exists; make up will reuse it"
fi
if [ "$cluster_exists" = 0 ]; then
  for port in 80 443; do
    # bash's /dev/tcp: the connection succeeds only if something listens.
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      fail "port $port is already in use; kind publishes 80 and 443 for the ingress"
      case "$platform" in
        wsl|gitbash) hint "Find the process in PowerShell: Get-NetTCPConnection -LocalPort $port -State Listen" \
                          "Often IIS or another local web server; stop it while the cluster runs." ;;
        macos)       hint "Find the process: sudo lsof -nP -iTCP:$port -sTCP:LISTEN" ;;
        *)           hint "Find the process: sudo ss -ltnp 'sport = :$port'" ;;
      esac
    else
      ok "port $port is free"
    fi
  done
fi

# --------------------------------------------------------------------- #
# Platform notes
# --------------------------------------------------------------------- #
if [ "$platform" = linux ] || [ "$platform" = wsl ]; then
  instances="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
  if [ "${instances:-0}" -lt 512 ]; then
    warn "fs.inotify.max_user_instances is $instances; with many pods kind nodes can fail with 'too many open files'"
    hint "sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288"
  fi
fi
if [ "$platform" = wsl ]; then
  case "$PWD" in
    /mnt/*)
      warn "the repository is on the Windows drive ($PWD)"
      hint "Clone it inside the Linux file system instead (for example: cd ~ && git clone https://github.com/ykstorm/stackup)." \
           "Builds and git are much faster there, and a clone made from Windows can have CRLF line endings." ;;
  esac
fi

printf '\n'
if [ "$problems" -gt 0 ]; then
  echo "FAIL $problems problem(s) found. Fix them and run make up (or ./setup.sh) again."
  exit 1
fi
echo "ok   preflight passed"
