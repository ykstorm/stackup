import Link from 'next/link';
import './globals.css';

export const metadata = {
  title: 'Stackup Docs',
  description:
    'One-command Kubernetes on a laptop: kind, an ArgoCD app-of-apps, and an Argo Rollouts canary gated on a Prometheus success rate.',
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <header>
          <nav aria-label="Pages">
            <Link href="/">Overview</Link>
            <Link href="/getting-started/">Getting Started</Link>
            <Link href="/architecture/">Architecture</Link>
            <Link href="/gitops-canary/">GitOps &amp; Canary</Link>
            <a href="https://github.com/ykstorm/stackup">GitHub</a>
          </nav>
        </header>
        <main>{children}</main>
        <footer>
          Stackup is licensed under the Apache License 2.0.{' '}
          <a href="https://github.com/ykstorm/stackup">Source on GitHub</a>.
        </footer>
      </body>
    </html>
  );
}
