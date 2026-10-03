{{/*
Sync policy shared by every child: automated sync with prune and self-heal,
and retries with backoff. The retries matter on a fresh cluster, where a sync
can fail once because a webhook it depends on is still starting.
*/}}
{{- define "stackup.syncPolicy" -}}
automated:
  prune: true
  selfHeal: true
retry:
  limit: 10
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 3m
{{- end -}}

{{/*
The admission webhooks of cert-manager, ingress-nginx and the Prometheus
operator get their caBundle filled in after install, by cert-manager's
cainjector or by a patch job. Git never has that field, so it is not a drift.
*/}}
{{- define "stackup.ignoreWebhookCaBundle" -}}
- group: admissionregistration.k8s.io
  kind: ValidatingWebhookConfiguration
  jqPathExpressions:
    - .webhooks[]?.clientConfig.caBundle
- group: admissionregistration.k8s.io
  kind: MutatingWebhookConfiguration
  jqPathExpressions:
    - .webhooks[]?.clientConfig.caBundle
{{- end -}}
