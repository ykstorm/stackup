export const metadata = {
  title: 'GitOps & Canary — Stackup',
};

const QUERY = `sum(rate(http_requests_total{service="demo-canary", rollouts_pod_template_hash="<hash>", code=~"2.."}[2m]))
/
sum(rate(http_requests_total{service="demo-canary", rollouts_pod_template_hash="<hash>"}[2m]))`;

export default function GitopsCanary() {
  return (
    <>
      <h1>GitOps &amp; Canary</h1>
      <p className="lede">
        How a commit turns into a canary rollout, what Prometheus measures,
        and what happens when the measurement fails.
      </p>

      <h2>The trigger</h2>
      <p>
        Build the new image into kind with{' '}
        <code>make demo-image DEMO_IMAGE=stackup-demo:v2</code>, then bump{' '}
        <code>image.tag</code> in <code>helm/demo/values.yaml</code>, commit, and
        push. ArgoCD polls the repository every two to three minutes, syncs the
        change, and Argo Rollouts starts a new revision. Watch it:
      </p>
      <pre>
        <code>{`make rollout-status
# kubectl argo rollouts get rollout demo -n app --watch`}</code>
      </pre>

      <h2>The steps</h2>
      <ol>
        <li>Set the canary weight to 25%, then pause 30 seconds.</li>
        <li>
          Run the analysis: after a 30-second delay, query Prometheus three
          times, 30 seconds apart.
        </li>
        <li>
          If the gate holds, move to 50%, 75% and 100%, pausing 30 seconds
          between steps.
        </li>
        <li>
          If two of the three measurements fail, abort: the new pods are scaled
          down and the old version keeps serving.
        </li>
      </ol>
      <p>
        There is no traffic router, so a weight is a share of the pods. With
        two replicas, the 25% step runs one new pod next to the two old ones.
      </p>

      <h2>The analysis query</h2>
      <p>
        The <code>AnalysisTemplate</code> in <code>helm/demo</code> computes the
        share of the new pods&apos; requests that returned a 2xx status over the
        last two minutes. Argo Rollouts fills in <code>&lt;hash&gt;</code>, the
        pod-template-hash of the new ReplicaSet:
      </p>
      <pre>
        <code>{QUERY}</code>
      </pre>
      <p>
        Prometheus adds both labels when it scrapes. <code>service</code> is the
        Kubernetes Service a sample came through: <code>demo-canary</code> is the
        Rollout&apos;s canary Service, which Argo Rollouts points at the new
        pods. <code>rollouts_pod_template_hash</code> is copied from each pod, and it
        leaves out samples the canary Service collected from the stable pods
        before that switch.
      </p>
      <p>
        A measurement passes when the result is at least 0.95. The template
        allows one failed measurement (<code>failureLimit: 1</code>); a second
        one fails the AnalysisRun. Because the query covers only the new pods,
        a version that fails more than about 5% of its real requests fails the
        gate.
      </p>

      <h2>Seeing it abort</h2>
      <p>
        Probes and Prometheus scrapes always return 200, so with no other
        traffic the ratio stays at 1.0. To watch the gate fail, start the curl
        pods in <code>ci/traffic.yaml</code>, then set{' '}
        <code>failureRate: &quot;0.5&quot;</code> in{' '}
        <code>helm/demo/values.yaml</code> and push. The new pods fail half of
        their <code>/api/work</code> calls, the ratio drops below 0.95, and the
        Rollout stops as <code>Degraded</code> with the old pods still serving.
        A revert brings it back to <code>Healthy</code>.
      </p>

      <h2>Why GitOps for this</h2>
      <p>
        The image tag lives in git and ArgoCD reconciles against it, so the
        rollout has one source of truth. There is no out-of-band{' '}
        <code>kubectl set image</code>. A reviewer can read the diff that
        triggered a deploy, and undoing it is a git revert. The canary gate then
        decides whether that change reaches every pod.
      </p>
    </>
  );
}
