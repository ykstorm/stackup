import Link from 'next/link';
import CanaryFlow from './components/CanaryFlow';

const GATE_QUERY =
  'sum(rate(http_requests_total{service="demo-canary", rollouts_pod_template_hash="<hash>", code=~"2.."}[2m])) / sum(rate(http_requests_total{service="demo-canary", rollouts_pod_template_hash="<hash>"}[2m]))';

const COMPONENTS = [
  ['Cluster', 'kind', 'One Kubernetes node running as a Docker container'],
  ['Network', 'Calico', 'Pod networking and NetworkPolicy enforcement in both directions'],
  ['GitOps', 'ArgoCD', 'A root Application syncs six child Applications from this repository'],
  ['Delivery', 'Argo Rollouts', "Runs the demo's canary steps and its analysis gate"],
  ['Metrics', 'kube-prometheus-stack', 'Prometheus and Grafana'],
  ['Ingress', 'ingress-nginx', "Serves *.localtest.me on ports 80 and 443 of the host's loopback address"],
  ['TLS', 'cert-manager', 'Certificates from a self-signed ClusterIssuer'],
  ['Secrets', 'Sealed Secrets', 'Decrypts SealedSecret resources inside the cluster'],
  ['Pod security', 'Pod Security Admission', 'The app namespace enforces the restricted profile'],
  ['Workload', 'demo (helm/demo)', 'Express service that counts every request in http_requests_total'],
];

export default function Home() {
  return (
    <>
      <h1>Stackup</h1>
      <p className="hero">
        Stackup brings up a single-node Kubernetes cluster on a laptop with one command. kind runs the
        cluster inside Docker, and ArgoCD keeps it in step with this repository. A small demo service
        ships through an Argo Rollouts canary: each new version starts on a share of the pods while
        Prometheus checks the HTTP success rate of those new pods, and the rollout either continues to 100%
        or rolls back on its own.
      </p>

      <h2>Run it</h2>
      <div className="run">
        <div>
          <pre>
            <code>{`git clone https://github.com/ykstorm/stackup
cd stackup
make up        # or ./setup.sh`}</code>
          </pre>
          <p className="note">
            <code>make up</code> checks the prerequisites, creates the cluster, installs Calico and ArgoCD, and
            loads the demo image onto the node. ArgoCD then installs the rest from git in three sync waves, and
            the script waits until every Application is healthy.
          </p>
        </div>
        <div>
          <h3>You need</h3>
          <ul className="prereqs">
            <li>Docker with at least 6 GB of memory</li>
            <li>
              <code>kind</code>, <code>kubectl</code>, and <code>helm</code> 3.15 or newer
            </li>
            <li>
              the <code>kubectl-argo-rollouts</code> plugin
            </li>
            <li>
              <code>git</code>, <code>bash</code> and <code>make</code> (on Windows, WSL, or Git Bash with{' '}
              <code>./setup.sh</code>)
            </li>
            <li>ports 80 and 443 free on the host</li>
            <li>
              <code>make preflight</code> checks all of this
            </li>
          </ul>
        </div>
      </div>

      <h2>How a change ships</h2>
      <figure className="flow">
        <div className="flow-scroll">
          <CanaryFlow />
        </div>
        <figcaption>
          The demo canary with the default values in <code>helm/demo</code>. The AnalysisRun computes{' '}
          <code>{GATE_QUERY}</code>, the share of requests to the new pods that returned a 2xx status, where{' '}
          <code>&lt;hash&gt;</code> is the new ReplicaSet&apos;s pod-template-hash. One failed measurement is
          tolerated; a second aborts the update.
        </figcaption>
      </figure>

      <h2>What you can open</h2>
      <div className="opens">
        <section className="open">
          <h3>ArgoCD</h3>
          <p className="addr">
            <a href="https://argocd.localtest.me">argocd.localtest.me</a>
          </p>
          <p>
            The root Application and its six children, with the sync and health of each. Log in as{' '}
            <code>admin</code>; the password is in the <code>argocd-initial-admin-secret</code> Secret.
          </p>
        </section>
        <section className="open">
          <h3>Grafana</h3>
          <p className="addr">
            <a href="https://grafana.localtest.me/d/stackup-canary">grafana.localtest.me/d/stackup-canary</a>
          </p>
          <p>
            The canary dashboard: the gate&apos;s success rate per ReplicaSet against the 0.95 line, requests by status code,
            5xx responses by pod, and ready pods per ReplicaSet. Log in as <code>admin</code> /{' '}
            <code>prom-operator</code>.
          </p>
        </section>
        <section className="open">
          <h3>The rollout</h3>
          <p className="addr">
            <code>make rollout-status</code>
          </p>
          <p>
            The Rollout&apos;s steps, ReplicaSets and AnalysisRuns, updating in the terminal.{' '}
            <code>make rollout-ui</code> serves the same view as a web page on{' '}
            <code>localhost:3100/rollouts</code>.
          </p>
        </section>
      </div>
      <p className="note">
        <code>localtest.me</code> resolves to <code>127.0.0.1</code>. The certificates are self-signed, so the
        browser warns once per host.
      </p>

      <h2>What gets installed</h2>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Layer</th>
              <th>Component</th>
              <th>What it does here</th>
            </tr>
          </thead>
          <tbody>
            {COMPONENTS.map(([layer, component, role]) => (
              <tr key={layer}>
                <td>{layer}</td>
                <td>{component}</td>
                <td>{role}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2>Read next</h2>
      <ul className="next">
        <li>
          <Link href="/getting-started/">Getting started</Link>: prerequisites, <code>make up</code>, and
          shipping a change.
        </li>
        <li>
          <Link href="/architecture/">Architecture</Link>: the node, the namespaces, the GitOps tree and the
          metrics path.
        </li>
        <li>
          <Link href="/gitops-canary/">GitOps &amp; canary</Link>: the steps, the query, and what happens when
          it fails.
        </li>
      </ul>
    </>
  );
}
