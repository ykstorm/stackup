import Link from 'next/link';

export default function Home() {
  return (
    <>
      <span className="tag">kind · ArgoCD · Argo Rollouts · Prometheus</span>
      <h1>Stackup</h1>
      <p className="lede">
        Stackup brings up a single-node Kubernetes cluster on a laptop with{' '}
        <code>make up</code>. ArgoCD keeps the cluster in step with the
        repository, and a demo service ships through an Argo Rollouts canary
        that Prometheus can stop.
      </p>

      <h2>What it is</h2>
      <p>
        A kind cluster with Calico, an ArgoCD app-of-apps over six child
        applications, Argo Rollouts for the canary, kube-prometheus-stack for
        metrics (Prometheus and Grafana), cert-manager with a self-signed
        issuer, and the Sealed Secrets controller. The <code>app</code>{' '}
        namespace enforces the <code>restricted</code> Pod Security profile.
      </p>

      <h2>The components</h2>
      <table>
        <thead>
          <tr>
            <th>Layer</th>
            <th>Component</th>
            <th>Role</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Cluster</td>
            <td>kind</td>
            <td>One Kubernetes node running as a Docker container</td>
          </tr>
          <tr>
            <td>Network</td>
            <td>Calico</td>
            <td>Pod networking and NetworkPolicy enforcement (ingress and egress)</td>
          </tr>
          <tr>
            <td>GitOps</td>
            <td>ArgoCD app-of-apps</td>
            <td>One root app manages six children; sync, prune, self-heal</td>
          </tr>
          <tr>
            <td>Delivery</td>
            <td>Argo Rollouts</td>
            <td>Canary from 25% to 100% with a success-rate gate that can abort</td>
          </tr>
          <tr>
            <td>Ingress</td>
            <td>ingress-nginx</td>
            <td>TLS on hostPort 80 and 443</td>
          </tr>
          <tr>
            <td>TLS</td>
            <td>cert-manager</td>
            <td>Certificates from a self-signed ClusterIssuer</td>
          </tr>
          <tr>
            <td>Secrets</td>
            <td>Sealed Secrets</td>
            <td>Controller that decrypts SealedSecret resources in the cluster</td>
          </tr>
          <tr>
            <td>Metrics</td>
            <td>kube-prometheus-stack</td>
            <td>Prometheus and Grafana</td>
          </tr>
          <tr>
            <td>Workload</td>
            <td>demo Helm chart</td>
            <td>Express service that counts requests in http_requests_total</td>
          </tr>
        </tbody>
      </table>

      <h2>Start here</h2>
      <div className="cards">
        <div className="card">
          <h3>
            <Link href="/getting-started/">Getting Started</Link>
          </h3>
          <p>Prerequisites, make up, and the URLs to open.</p>
        </div>
        <div className="card">
          <h3>
            <Link href="/architecture/">Architecture</Link>
          </h3>
          <p>The node, the namespaces, the GitOps tree, and the metrics path.</p>
        </div>
        <div className="card">
          <h3>
            <Link href="/gitops-canary/">GitOps &amp; Canary</Link>
          </h3>
          <p>How a commit becomes a canary rollout with a Prometheus gate.</p>
        </div>
      </div>
    </>
  );
}
