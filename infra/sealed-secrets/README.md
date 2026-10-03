# sealed-secrets

The Sealed Secrets controller lets encrypted Secret material live in git. The controller in the cluster decrypts each `SealedSecret` into a regular `Secret`.

## How it is installed

`scripts/bootstrap.sh` applies the upstream release manifest for `v0.27.1`, which creates the `sealed-secrets-controller` Deployment and Service in `kube-system`. The ArgoCD Application in `argocd/apps/sealed-secrets.yaml` points at the project's Helm chart instead.

## Verify

```sh
kubectl get pods -n kube-system -l name=sealed-secrets-controller
# expect: 1/1 Running

kubeseal --version
```

## Encrypting a Secret

`kubeseal` looks for a controller named `sealed-secrets-controller` in `kube-system` by default, which is what the release manifest creates.

```sh
# 1. Write the plaintext Secret to a file; do not apply it.
kubectl create secret generic example \
  --from-literal=KEY=value \
  --dry-run=client -o yaml > /tmp/example.yaml

# 2. Encrypt it. The output is safe to commit.
kubeseal --format yaml < /tmp/example.yaml > example-sealed.yaml

# 3. Apply the SealedSecret. The controller creates the matching Secret.
kubectl apply -f example-sealed.yaml
kubectl get secret example -o yaml
```

## The key is per cluster

The controller generates its sealing key on first start and stores it as a Secret in `kube-system`. That key exists only in this kind cluster. After `make down` and `make up`, a new controller generates a new key, and anything sealed against the old one no longer decrypts; the controller logs `no key could decrypt secret`.

To keep sealed values across rebuilds, back the key up before deleting the cluster and restore it before the controller starts:

```sh
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-key.yaml        # keep this out of git

kubectl apply -f sealed-secrets-key.yaml
kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
```
