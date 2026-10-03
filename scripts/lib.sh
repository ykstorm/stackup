# Helpers shared by bootstrap.sh, smoke.sh and port-forward.sh. Source this
# file; it does nothing on its own.
# shellcheck shell=bash

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# k: kubectl against the stackup cluster, whatever the current context is.
STACKUP_CONTEXT="${STACKUP_CONTEXT:-kind-stackup}"
k() { kubectl --context "$STACKUP_CONTEXT" "$@"; }

# retry <attempts> <delay seconds> <command...>
# Progress goes to stderr, so it shows even when the caller hides stdout.
retry() {
  local attempts="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    info "attempt $n of $attempts failed; trying again in ${delay}s" >&2
    sleep "$delay"
    n=$((n + 1))
  done
}

# demo_image: the image the demo Rollout runs, as the chart renders it with
# values.dev.yaml (the values the ArgoCD demo Application uses).
demo_image() {
  helm template demo helm/demo -f helm/demo/values.dev.yaml --show-only templates/rollout.yaml \
    | awk '$1 == "image:" { gsub(/"/, "", $2); print $2; exit }'
}

# node_image_ref <image>: the name containerd on the kind node stores an image
# under, e.g. stackup-demo:v1 -> docker.io/library/stackup-demo:v1.
node_image_ref() {
  local image="$1" first="${1%%/*}"
  case "$image" in
    */*)
      case "$first" in
        *.*|*:*|localhost) printf '%s\n' "$image" ;;
        *) printf 'docker.io/%s\n' "$image" ;;
      esac
      ;;
    *) printf 'docker.io/library/%s\n' "$image" ;;
  esac
}

# app_table: one "<name> <sync> <health>" line per ArgoCD Application;
# fields that are not set yet read <none>.
app_table() {
  k get applications.argoproj.io -n argocd --no-headers \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null
}

# app_state <table> <name>: "Synced/Healthy", "OutOfSync/Progressing", ...
app_state() {
  awk -v a="$2" '$1 == a { print $2 "/" $3; found = 1 } END { if (!found) print "missing" }' <<<"$1"
}

# Port-forwards ---------------------------------------------------------- #

PF_PIDS=()

# pf_start <namespace> <service> <local port> <service port>
pf_start() {
  k port-forward -n "$1" "svc/$2" "$3:$4" >/dev/null 2>&1 &
  PF_PIDS+=("$!")
}

# pf_wait <local port> <seconds>: wait until something answers HTTP there.
pf_wait() {
  local port="$1" deadline
  deadline=$(( $(date +%s) + $2 ))
  until curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 1
  done
}

pf_stop_all() {
  local pid
  for pid in ${PF_PIDS[@]+"${PF_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  PF_PIDS=()
}
