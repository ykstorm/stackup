# Demo workload image — the stackup canary subject.
#
# Build (from repo root):
#   docker build -t stackup-demo:v1 apps/demo
#
# Load into the kind cluster (image is never pushed to a registry; kind
# side-loads it so ImagePullPolicy=IfNotPresent resolves locally):
#   kind load docker-image stackup-demo:v1 --name stackup
#
# A "bad" build for the rollback demo just bakes a higher failure rate:
#   docker build -t stackup-demo:v2 --build-arg FAILURE_RATE=0.3 apps/demo
#   kind load docker-image stackup-demo:v2 --name stackup
FROM node:20-alpine

WORKDIR /app

# Install production deps first for layer caching, at the versions in
# package-lock.json.
COPY package*.json ./
RUN npm ci --omit=dev

COPY server.js ./

# Default failure rate baked into the image; override per-build for the
# rollback demo, or at runtime via the FAILURE_RATE env var.
ARG FAILURE_RATE=0
ENV FAILURE_RATE=${FAILURE_RATE}
ENV PORT=3000
ENV SERVICE_NAME=demo

# Run as a non-root UID so the pod satisfies restricted Pod Security
# Standards (runAsNonRoot + runAsUser in the chart's securityContext).
USER 1001

EXPOSE 3000
CMD ["node", "server.js"]
