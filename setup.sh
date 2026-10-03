#!/usr/bin/env bash
# One-command setup: check the prerequisites, then bring the cluster up.
# Run it from Linux, macOS, WSL or Git Bash: ./setup.sh (make up runs it too).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

bash scripts/preflight.sh
bash scripts/bootstrap.sh
