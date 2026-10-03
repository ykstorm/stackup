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
          <code>git</code> and <code>bash</code>, plus <code>make</code> for the
          make targets.
        </li>
        <li>Ports 80 and 443 free on the host.</li>
        <li>
          Network access to GitHub and the Helm chart repositories: ArgoCD
          installs the components from there.
        </li>
      </ul>
      <p>
        <code>make preflight</code> checks all of these and prints the install
        command for anything missing.
      </p>

      <h2>Bring it up</h2>
      <pre>
        <code>{`git clone https://github.com/ykstorm/stackup && cd stackup
make up        # or ./setup.sh`}</code>
      </pre>
      <p>
        <code>make up</code> runs <code>./setup.sh</code>: the preflight check,
        then <code>scripts/bootstrap.sh</code>. The bootstrap creates the kind
        cluster, installs Calico and ArgoCD (its CRDs first), builds the{' '}
        <code>demo</code> image and loads it into the node, and applies the root
        ArgoCD Application. ArgoCD then installs everything else from git in
        three sync waves, and the script waits until every Application is
        Synced and Healthy. The first run pulls every image, so it is the slow
        one; running <code>make up</code> again reuses the cluster.
      </p>

      <h2>Windows and WSL</h2>
      <ul>
        <li>
          Use WSL 2, with Docker Desktop&apos;s WSL integration turned on or
          Docker Engine installed inside WSL. Clone the repository into the
          Linux file system (<code>~/stackup</code>, not{' '}
          <code>/mnt/c/...</code>), then run <code>make up</code>.
        </li>
        <li>
          Git Bash with Docker Desktop works too. Git for Windows has no{' '}
          <code>make</code>, so run <code>./setup.sh</code>.
        </li>
        <li>
          PowerShell and cmd cannot run the scripts; <code>make</code> started
          from either stops with a message.
        </li>
      </ul>
      <p>
        <code>docs/troubleshooting.md</code> in the repository lists the errors
        seen on Windows and WSL and the fix for each.
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
      <p>
        If those addresses do not answer, <code>make port-forward</code> serves
        the same UIs on localhost: ArgoCD on <code>http://localhost:8080</code>,
        Grafana on <code>http://localhost:3000</code>, Prometheus on{' '}
        <code>http://localhost:9090</code> and the demo on{' '}
        <code>http://localhost:8081</code>. <code>make smoke</code> checks the
        whole cluster from the command line.
      </p>

      <h2>Ship a change</h2>
      <p>
        ArgoCD syncs <code>main</code> of <code>ykstorm/stackup</code>. To
        deploy your own changes, fork it and run{' '}
        <code>STACKUP_REPO=https://github.com/&lt;you&gt;/stackup make up</code>
        ; <code>STACKUP_REVISION</code> picks another branch, tag or commit.
        Then:
      </p>
      <pre>
        <code>{`make demo-image DEMO_IMAGE=stackup-demo:v2   # build v2 and load it into kind
# set image.tag: v2 in helm/demo/values.yaml, commit, push
make rollout-status                           # watch the canary`}</code>
      </pre>

      <h2>Makefile targets</h2>
      <pre>
        <code>{`make help            # list targets
make up              # check the prerequisites, create the cluster, install everything
make preflight       # only check the prerequisites
make smoke           # check the running cluster
make port-forward    # ArgoCD, Grafana, Prometheus and the demo on localhost ports
make rollout-status  # watch the demo Rollout in the terminal
make rollout-ui      # Argo Rollouts dashboard on localhost:3100/rollouts
make demo-image      # build the demo image and load it into kind
make lint            # static checks: YAML, scripts, chart renders (no cluster)
make down            # delete the kind cluster`}</code>
      </pre>

      <h2>Known limits</h2>
      <ul>
        <li>
          kind has no LoadBalancer, so ingress uses hostPort 80 and 443 on the
          single node; <code>make port-forward</code> is the way in when those
          ports are not reachable.
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
