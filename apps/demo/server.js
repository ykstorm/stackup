// stackup demo workload — the canary subject.
//
// A self-contained Express service that exposes a real Prometheus
// metrics endpoint. This is the workload the Argo Rollouts
// AnalysisTemplate measures: every request increments
// `http_requests_total{service,code,method,path}`, and the canary
// success-rate query is computed from that counter.
//
// Deliberately tiny and dependency-light (express + prom-client only) so
// it builds into a small image and boots in well under a second on kind.
//
// Endpoints:
//   GET /            -> 200, liveness/landing
//   GET /healthz     -> 200, readiness/liveness probe target
//   GET /api/work    -> 200 normally; 500 for FAILURE_RATE of requests when
//                       FAILURE_RATE is set (used to demo an automatic
//                       canary rollback on a bad image)
//   GET /metrics     -> Prometheus exposition of http_requests_total + defaults

const express = require("express");
const promClient = require("prom-client");

const app = express();

const SERVICE_NAME = process.env.SERVICE_NAME || "demo";
const PORT = parseInt(process.env.PORT || "3000", 10);
// FAILURE_RATE in [0,1]: fraction of /api/work requests that return 500.
// The chart sets it from failureRate (helm/demo/values.yaml). The canary
// gate measures the canary pods alone, so a rate above 0.05 takes their
// success ratio under the 0.95 threshold once /api/work traffic outweighs
// the probe and scrape requests, and Argo Rollouts aborts the canary.
const FAILURE_RATE = parseFloat(process.env.FAILURE_RATE || "0");

// Default process/runtime metrics (event loop lag, heap, GC, ...).
promClient.collectDefaultMetrics({ labels: { service: SERVICE_NAME } });

// The metric the canary analysis reads; its query matches on `code`. The
// `service` label set here is kept as `exported_service` when Prometheus
// scrapes through a Service, and the query matches the Service name instead.
const httpRequestsTotal = new promClient.Counter({
  name: "http_requests_total",
  help: "Total HTTP requests processed, labelled by service, method, path and status code.",
  labelNames: ["service", "method", "path", "code"],
});

// Middleware: on every response 'finish', record exactly one increment with
// the final status code. Registered before routes so it wraps all of them.
app.use((req, res, next) => {
  res.on("finish", () => {
    httpRequestsTotal.inc({
      service: SERVICE_NAME,
      method: req.method,
      // req.route?.path is the matched route pattern (stable label,
      // low-cardinality); fall back to the raw path for unmatched routes.
      path: (req.route && req.route.path) || req.path || "unknown",
      code: String(res.statusCode),
    });
  });
  next();
});

app.get("/", (_req, res) => {
  res.json({ service: SERVICE_NAME, ok: true });
});

app.get("/healthz", (_req, res) => {
  res.json({ status: "ok" });
});

app.get("/api/work", (_req, res) => {
  // Simulate a unit of work that fails FAILURE_RATE of the time.
  if (FAILURE_RATE > 0 && Math.random() < FAILURE_RATE) {
    return res.status(500).json({ error: "injected_failure" });
  }
  return res.json({ result: "ok" });
});

app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", promClient.register.contentType);
  res.send(await promClient.register.metrics());
});

// Only listen when run directly; exporting the app keeps it testable.
if (require.main === module) {
  const server = app.listen(PORT, () => {
    // eslint-disable-next-line no-console
    console.log(`${SERVICE_NAME} listening on :${PORT} (failureRate=${FAILURE_RATE})`);
  });
  // Kubernetes sends SIGTERM when a pod is replaced. Without this handler the
  // process ignores it and the pod waits out the 30 s grace period.
  process.on('SIGTERM', () => {
    server.close(() => process.exit(0));
  });
}

module.exports = { app, register: promClient.register };
