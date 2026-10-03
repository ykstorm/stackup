# Contributing

1. Fork the repository and branch from `main`.
2. Keep the change small and focused.
3. Run `make lint` and `make smoke` before opening a pull request. Neither needs a cluster; both need `helm` and `python3` with PyYAML.
4. Open a pull request that says what changed and why. CI must pass.

For anything large, open an issue first to talk it through.

Commit messages follow Conventional Commits, for example `fix: correct the ingress-nginx hostPort mapping` or `docs: update the quickstart`.
