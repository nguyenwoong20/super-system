#!/bin/bash
# ============================================================
# PHASE 2: Build & Push Docker Images to ECR
# File: infra/scripts/02-build-push.sh
#
# Build tất cả Docker images và push lên Amazon ECR
# Usage: ./02-build-push.sh [--tag <tag>]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -W)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/outputs.env"

IMAGE_TAG="${1:-latest}"
GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "manual")

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   🐳 PHASE 2: Build & Push to ECR               ║"
echo "║   Tag: ${IMAGE_TAG} (git: ${GIT_SHA})            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Login to ECR ───────────────────────────────────────────
echo "▶ [1/4] Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
echo "   ✅ ECR login successful"

# ── Helper: build + tag + push ─────────────────────────────
build_and_push() {
  local name=$1
  local context=$2
  local dockerfile=$3
  local ecr_uri=$4

  echo ""
  echo "▶ Building: ${name}..."
  docker build \
    --platform linux/amd64 \
    -t "${name}:${IMAGE_TAG}" \
    -t "${name}:${GIT_SHA}" \
    -f "${dockerfile}" \
    "${context}"

  echo "   ▶ Tagging & pushing to ECR..."
  docker tag "${name}:${IMAGE_TAG}" "${ecr_uri}:${IMAGE_TAG}"
  docker tag "${name}:${IMAGE_TAG}" "${ecr_uri}:${GIT_SHA}"
  docker push "${ecr_uri}:${IMAGE_TAG}"
  docker push "${ecr_uri}:${GIT_SHA}"
  echo "   ✅ Pushed: ${ecr_uri}:${IMAGE_TAG}"
}

# ── 2. Build Nginx Gateway ─────────────────────────────────
echo "▶ [2/4] Building Nginx Gateway..."
# Copy nginx.conf into gateway-proxy context first
cp "${PROJECT_ROOT}/infra/nginx/nginx.conf" "${PROJECT_ROOT}/src/gateway-proxy/nginx.conf"

# Update Dockerfile to use local nginx.conf copy
cat > "${PROJECT_ROOT}/src/gateway-proxy/Dockerfile" << 'DOCKERFILE'
FROM nginx:1.25-alpine
RUN apk add --no-cache curl
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf
RUN mkdir -p /var/log/nginx
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:80/health || exit 1
CMD ["nginx", "-g", "daemon off;"]
DOCKERFILE

build_and_push \
  "nginx-gateway" \
  "${PROJECT_ROOT}/src/gateway-proxy" \
  "${PROJECT_ROOT}/src/gateway-proxy/Dockerfile" \
  "$ECR_NGINX"

# ── 3. Build Auth Service ──────────────────────────────────
echo "▶ [3/4] Building Auth Service (NestJS)..."
build_and_push \
  "auth-service" \
  "${PROJECT_ROOT}/src/service-auth" \
  "${PROJECT_ROOT}/src/service-auth/Dockerfile" \
  "$ECR_AUTH"

# ── 4. Build Ticket Service ────────────────────────────────
echo "▶ [4/4] Building Ticket Service (NestJS)..."
build_and_push \
  "ticket-service" \
  "${PROJECT_ROOT}/src/service-tickets" \
  "${PROJECT_ROOT}/src/service-tickets/Dockerfile" \
  "$ECR_TICKETS"

# Save image URIs with tags
{
  echo "IMAGE_TAG=${IMAGE_TAG}"
  echo "GIT_SHA=${GIT_SHA}"
  echo "ECR_NGINX_IMAGE=${ECR_NGINX}:${IMAGE_TAG}"
  echo "ECR_AUTH_IMAGE=${ECR_AUTH}:${IMAGE_TAG}"
  echo "ECR_TICKETS_IMAGE=${ECR_TICKETS}:${IMAGE_TAG}"
} >> "${SCRIPT_DIR}/outputs.env"

# ── Summary ────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅ PHASE 2 COMPLETE — All images pushed        ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "   📦 nginx-gateway : ${ECR_NGINX}:${IMAGE_TAG}"
echo "   📦 auth-service  : ${ECR_AUTH}:${IMAGE_TAG}"
echo "   📦 ticket-service: ${ECR_TICKETS}:${IMAGE_TAG}"
echo ""
echo "▶  Next: run ./03-ecs-setup.sh"
