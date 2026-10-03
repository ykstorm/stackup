# Contributing

1. Fork the repository and branch from `main`.
2. Keep the change small and focused.
3. Run `make lint` before opening a pull request. It needs no cluster, only `helm`, `kubeconform`, and `python3` with PyYAML; it also runs `shellcheck` when that is installed. CI runs the same script and treats a missing tool as a failure.
4. Open a pull request that says what changed and why. CI must pass.

For anything large, open an issue first to talk it through.

Commit messages follow Conventional Commits, for example `fix: correct the ingress-nginx hostPort mapping` or `docs: update the quickstart`.
