# ============================================================
# Auth Service — Dockerfile
# File: src/service-auth/Dockerfile
# ============================================================
# Multi-stage build:
#   Stage 1 (builder): install deps + compile TypeScript
#   Stage 2 (runner):  copy only dist + node_modules (prod)
# ============================================================

# ── Stage 1: Builder ──────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Copy package files first (better layer caching)
COPY package*.json ./

# Install all dependencies (including devDeps for build)
RUN npm install

# Copy source code
COPY . .

# Compile TypeScript → dist/
RUN npm run build

# ── Stage 2: Production Runner ────────────────────────────
FROM node:20-alpine AS runner

# Install curl for health check
RUN apk add --no-cache curl

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install ONLY production dependencies
RUN npm install --omit=dev && npm cache clean --force

# Copy compiled output from builder
COPY --from=builder /app/dist ./dist

# Non-root user for security
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

# Expose NestJS port
EXPOSE 3001

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:3001/auth/health || exit 1

# Start the compiled NestJS app
CMD ["node", "dist/main"]
