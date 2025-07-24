# Use the official uv image as base
FROM ghcr.io/astral-sh/uv:debian AS base

# Install Node.js and pnpm directly
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && npm install -g pnpm@10.12.0 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# -----------------------------
# deps stage: install workspace deps
# -----------------------------
FROM base AS deps
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

# Root package files
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY turbo.json ./

# Workspace package.json files
COPY apps/frontend/package.json                 ./apps/frontend/
COPY apps/backend/package.json                  ./apps/backend/
COPY packages/eslint-config/package.json        ./packages/eslint-config/
COPY packages/trpc/package.json                 ./packages/trpc/
COPY packages/typescript-config/package.json    ./packages/typescript-config/
COPY packages/zod-types/package.json            ./packages/zod-types/

# Install all deps (cached for builder)
RUN pnpm install --frozen-lockfile

# -----------------------------
# builder stage: build everything
# -----------------------------
FROM base AS builder
WORKDIR /app

# Bring in deps
COPY --from=deps /app/node_modules                     ./node_modules
COPY --from=deps /app/apps/frontend/node_modules       ./apps/frontend/node_modules
COPY --from=deps /app/apps/backend/node_modules        ./apps/backend/node_modules
COPY --from=deps /app/packages                         ./packages

# Source + build
COPY . .
RUN pnpm build

# -----------------------------
# runner stage: final production image
# -----------------------------
FROM base AS runner
WORKDIR /app

# Make sure Postgres binaries are reachable
ENV PATH="/usr/lib/postgresql/15/bin:${PATH}"
# Tell postgres where to store its data at runtime (owned by nextjs)
ENV PGDATA=/app/pgdata

# OCI image labels
LABEL org.opencontainers.image.source="https://github.com/metatool-ai/metamcp"
LABEL org.opencontainers.image.description="MetaMCP - aggregates MCP servers into a unified MetaMCP"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="MetaMCP"
LABEL org.opencontainers.image.vendor="metatool-ai"

# Install curl, PostgreSQL server & client
RUN apt-get update && apt-get install -y \
    curl \
    postgresql \
    postgresql-client \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Create app user
RUN addgroup --system --gid 1001 nodejs \
 && adduser  --system --uid 1001 --home /home/nextjs nextjs \
 && mkdir -p /home/nextjs/.local/share/pnpm/store/v3 \
 && mkdir -p "$PGDATA" \
 && chown -R nextjs:nodejs /home/nextjs "$PGDATA"

# Copy built outputs (as nextjs)
COPY --from=builder --chown=nextjs:nodejs /app/apps/frontend/.next              ./apps/frontend/.next
COPY --from=builder --chown=nextjs:nodejs /app/apps/frontend/package.json       ./apps/frontend/
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/dist                ./apps/backend/dist
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/package.json        ./apps/backend/
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/drizzle             ./apps/backend/drizzle
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/drizzle.config.ts   ./apps/backend/
COPY --from=builder --chown=nextjs:nodejs /app/packages                         ./packages
COPY --from=builder --chown=nextjs:nodejs /app/node_modules                     ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json                     ./
COPY --from=builder --chown=nextjs:nodejs /app/pnpm-workspace.yaml              ./

# Copy entrypoint & mark executable
COPY --chown=nextjs:nodejs docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Final ownership sweep (safe no-op if already owned)
RUN chown -R nextjs:nodejs /app

# Switch to non-root
USER nextjs

# Expose ports
EXPOSE 12008 12009

# Health check
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:12008/health || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
