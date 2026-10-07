# Demo workload image — the stackup canary subject.
#
# Build (from repo root):
#   docker build -t stackup-demo:v1 apps/demo
#
# Load into the kind cluster (image is never pushed to a registry; kind
# side-loads it so ImagePullPolicy=IfNotPresent resolves locally):
#   kind load docker-image stackup-demo:v1 --name stackup
#
# A bad version for the rollback demo is a chart value, not a new image: the
# chart always sets FAILURE_RATE in the pod from failureRate in
# helm/demo/values.yaml, and that overrides the ENV below. The canary gate
# measures the canary pods alone, so any failureRate above 0.05 fails it once
# real traffic reaches them (ci/traffic.yaml); the CI e2e uses
# --set failureRate=1.
FROM node:20-alpine

WORKDIR /app

# Install production deps first for layer caching, at the versions in
# package-lock.json.
COPY package*.json ./
RUN npm ci --omit=dev

COPY server.js ./

# Default failure rate for the image run on its own (docker run -e
# FAILURE_RATE=0.3 ...). Under the chart the pod's FAILURE_RATE replaces it.
ARG FAILURE_RATE=0
ENV FAILURE_RATE=${FAILURE_RATE}
ENV PORT=3000
ENV SERVICE_NAME=demo

# Run as a non-root UID so the pod satisfies restricted Pod Security
# Standards (runAsNonRoot + runAsUser in the chart's securityContext).
USER 1001

EXPOSE 3000
CMD ["node", "server.js"]
