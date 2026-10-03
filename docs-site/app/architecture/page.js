export const metadata = {
  title: 'Architecture — Stackup',
};

export default function Architecture() {
  return (
    <>
      <h1>Architecture</h1>
      <p className="lede">
        The node, the GitOps tree, the metrics path, and the security
        settings, as <code>make up</code> builds them.
      </p>

      <h2>The cluster</h2>
      <p>
        <code>kind/cluster.yaml</code> defines one node: a control-plane node
        that also runs every workload. The node is a Docker container running
        containerd and the kubelet, so pods are containers inside that
        container. The cluster sets <code>disableDefaultCNI: true</code> and
        installs Calico, which enforces both the ingress and the egress half of
        a NetworkPolicy. The node publishes ports 80 and 443 to the host, where
        ingress-nginx binds them. The stack needs about 6 GB of memory for
        Docker.
      </p>

      <h2>The GitOps tree</h2>
      <p>
        <code>make up</code> installs only kind, Calico, the <code>app</code>{' '}
        namespace and ArgoCD, loads the demo image onto the node, and applies
        one root ArgoCD Application. The root renders{' '}
        <code>argocd/apps/</code>, a small Helm chart that defines six child
        applications, and ArgoCD installs them in three sync waves:
      </p>
      <ul>
        <li>wave 0, cert-manager: certificates for each Ingress</li>
        <li>wave 0, ingress-nginx: the ingress controller</li>
        <li>wave 1, kube-prometheus-stack: Prometheus and Grafana</li>
        <li>wave 1, argo-rollouts: the canary controller</li>
        <li>wave 1, sealed-secrets: decrypts SealedSecret resources</li>
        <li>wave 2, demo: the canary subject, from the chart in helm/demo</li>
      </ul>
      <p>
        Each wave waits for the previous one to be Healthy, so the demo finds
        the Rollout and ServiceMonitor CRDs it needs. Each child syncs
        automatically with prune and self-heal turned on, and applies
        server-side, because several of the charts ship CRDs too large for a
        client-side apply. State lives in git rather than in{' '}
        <code>kubectl apply</code> commands.
      </p>

      <h2>Metrics</h2>
      <p>
        The demo app counts every response in{' '}
        <code>http_requests_total</code>, labelled by service, method, path and
        status code. kube-prometheus-stack scrapes it through the chart&apos;s
        ServiceMonitor:
      </p>
      <table>
        <thead>
          <tr>
            <th>Signal</th>
            <th>Path</th>
            <th>Store</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Metrics</td>
            <td>
              <code>/metrics</code>, scraped every 30s
            </td>
            <td>Prometheus</td>
          </tr>
        </tbody>
      </table>
      <p>
        Grafana reads from that Prometheus. There is no alerting and no log or
        trace pipeline: the stack collects metrics only.
      </p>

      <h2>Security settings</h2>
      <table>
        <thead>
          <tr>
            <th>Area</th>
            <th>Setting</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Pod admission</td>
            <td>
              The <code>app</code> namespace enforces the{' '}
              <code>restricted</code> Pod Security profile
            </td>
          </tr>
          <tr>
            <td>Pods</td>
            <td>
              Non-root UID, read-only root filesystem, no capabilities, no
              service account token
            </td>
          </tr>
          <tr>
            <td>Network</td>
            <td>
              Calico enforces NetworkPolicy in both directions. In{' '}
              <code>app</code>, everything is denied by default except DNS,
              in-namespace calls to the demo, and ingress-nginx and Prometheus
              connecting to it
            </td>
          </tr>
          <tr>
            <td>Secrets</td>
            <td>Sealed Secrets controller with a per-cluster key</td>
          </tr>
          <tr>
            <td>TLS</td>
            <td>cert-manager with a self-signed ClusterIssuer</td>
          </tr>
        </tbody>
      </table>

      <h2>Moving off kind</h2>
      <p>
        On a managed cluster the main changes are a multi-node control plane, a
        LoadBalancer Service for ingress-nginx instead of hostPort, an ACME
        issuer instead of the self-signed one, persistent volumes for
        Prometheus and Grafana, a backup of the Sealed Secrets key, and a
        traffic router so canary weights are exact shares of traffic rather
        than pod counts.
      </p>
    </>
  );
}
