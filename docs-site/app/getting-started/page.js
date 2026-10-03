export const metadata = {
  title: 'Getting Started — Stackup',
};

export default function GettingStarted() {
  return (
    <>
      <h1>Getting Started</h1>
      <p className="lede">
        Install the prerequisites, run one command, and open the cluster in a
        browser.
      </p>

      <h2>Prerequisites</h2>
      <ul>
        <li>
          Docker, with at least 6 GB of memory available to it (Docker Desktop:
          Settings, Resources). Below about 4 GB the controllers crash-loop.
        </li>
        <li>
          <code>kind</code>, <code>kubectl</code>, and <code>helm</code> 3.15 or
          newer.
        </li>
        <li>
          The <code>kubectl-argo-rollouts</code> plugin, used by{' '}
          <code>make rollout-status</code> and <code>make rollout-ui</code>.
        </li>
        <li>
          <code>git</code>, <code>bash</code> and <code>make</code>. On
          Windows, run from Git Bash or WSL; without <code>make</code>, run{' '}
          <code>bash scripts/bootstrap.sh</code>.
        </li>
        <li>Ports 80 and 443 free on the host.</li>
      </ul>

      <h2>Bring it up</h2>
      <pre>
        <code>{`git clone https://github.com/ykstorm/stackup && cd stackup
make up`}</code>
      </pre>
      <p>
        <code>make up</code> runs <code>scripts/bootstrap.sh</code>. It creates
        the kind cluster, installs Calico and the platform charts one at a time
        (waiting for each), builds the <code>demo</code> image and loads it into
        kind, installs the demo chart, and applies the root ArgoCD Application.
        From then on ArgoCD manages everything from git.
      </p>

      <h2>Open the cluster</h2>
      <p>
        Hostnames under <code>localtest.me</code> resolve to{' '}
        <code>127.0.0.1</code>, so there is nothing to add to a hosts file.
        Certificates are self-signed, so the browser warns once per host.
      </p>
      <ul>
        <li>
          <strong>https://grafana.localtest.me</strong>: log in as{' '}
          <code>admin</code> / <code>prom-operator</code>, the chart default.
          The canary dashboard is at{' '}
          <strong>https://grafana.localtest.me/d/stackup-canary</strong>.
        </li>
        <li>
          <strong>https://argocd.localtest.me</strong>: log in as{' '}
          <code>admin</code>. The password is in the{' '}
          <code>argocd-initial-admin-secret</code> Secret in the{' '}
          <code>argocd</code> namespace.
        </li>
        <li>
          The rollout, in the terminal: <code>make rollout-status</code>. In a
          browser: <code>make rollout-ui</code> serves the Argo Rollouts
          dashboard on <code>http://localhost:3100/rollouts</code>.
        </li>
        <li>
          <strong>https://demo.localtest.me</strong>: the demo service.{' '}
          <code>curl -k https://demo.localtest.me/metrics</code> shows{' '}
          <code>http_requests_total</code>.
        </li>
      </ul>

      <h2>Ship a change</h2>
      <p>
        ArgoCD tracks <code>main</code> of the repository named in{' '}
        <code>argocd/</code>, which is <code>ykstorm/stackup</code>. To deploy
        from git yourself, fork it and replace that URL with your fork&apos;s
        before running <code>make up</code>. Then:
      </p>
      <pre>
        <code>{`make demo-image DEMO_IMAGE=stackup-demo:v2   # build v2 and load it into kind
# set image.tag: v2 in helm/demo/values.yaml, commit, push
make rollout-status                           # watch the canary`}</code>
      </pre>

      <h2>Makefile targets</h2>
      <pre>
        <code>{`make help            # list targets
make up              # create the cluster and install everything
make down            # delete the kind cluster
make demo-image      # build the demo image and load it into kind
make lint            # static checks: YAML, scripts, chart renders (no cluster)
make rollout-status  # watch the demo Rollout in the terminal
make rollout-ui      # Argo Rollouts dashboard on localhost:3100/rollouts`}</code>
      </pre>

      <h2>Known limits</h2>
      <ul>
        <li>
          kind has no LoadBalancer, so ingress uses hostPort 80 and 443 on the
          single node.
        </li>
        <li>
          Nothing is persisted. Prometheus and Grafana use{' '}
          <code>emptyDir</code>, and <code>make down</code> deletes the
          cluster.
        </li>
        <li>
          The Sealed Secrets controller creates a new key for each cluster, so
          anything sealed against one cluster will not decrypt on the next.
        </li>
        <li>
          The <code>demo</code> service is a stand-in for a real one. It exists
          so the canary has real request metrics to judge.
        </li>
      </ul>
    </>
  );
}
