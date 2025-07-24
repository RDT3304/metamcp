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

# Install dependencies only when needed
FROM base AS deps
WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED=1

# Copy root package files
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY turbo.json ./

# Copy package.json files from all workspaces
COPY apps/frontend/package.json ./apps/frontend/
COPY apps/backend/package.json ./apps/backend/
COPY packages/eslint-config/package.json ./packages/eslint-config/
COPY packages/trpc/package.json ./packages/trpc/
COPY packages/typescript-config/package.json ./packages/typescript-config/
COPY packages/zod-types/package.json ./packages/zod-types/

# Install deps
RUN pnpm install --frozen-lockfile

# Builder stage
FROM base AS builder
WORKDIR /app

# Copy deps
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/apps/frontend/node_modules ./apps/frontend/node_modules
COPY --from=deps /app/apps/backend/node_modules ./apps/backend/node_modules
COPY --from=deps /app/packages ./packages

# Copy source & build
COPY . .
RUN pnpm build

# Production runner stage
FROM base AS runner
WORKDIR /app

# OCI image labels
LABEL org.opencontainers.image.source="https://github.com/metatool-ai/metamcp"
LABEL org.opencontainers.image.description="MetaMCP - aggregates MCP servers into a unified MetaMCP"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="MetaMCP"
LABEL org.opencontainers.image.vendor="metatool‑ai"

# Install curl, PostgreSQL & client
RUN apt-get update && apt-get install -y \
    curl \
    postgresql \
    postgresql-client \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Initialize PostgreSQL (must be done as postgres)
USER postgres
RUN /usr/lib/postgresql/15/bin/initdb -D /var/lib/postgresql/data

# Back to root for user setup
USER root

# Create non‑root group & user
RUN addgroup --system --gid 1001 nodejs
RUN adduser  --system --uid 1001 --home /home/nextjs nextjs && \
    mkdir -p /home/nextjs/.cache/node/corepack && \
    chown -R nextjs:nodejs /home/nextjs

# Copy in built artifacts, setting ownership
COPY --from=builder --chown=nextjs:nodejs /app/apps/frontend/.next ./apps/frontend/.next
COPY --from=builder --chown=nextjs:nodejs /app/apps/frontend/package.json ./apps/frontend/
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/dist ./apps/backend/dist
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/package.json ./apps/backend/
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/drizzle ./apps/backend/drizzle
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/drizzle.config.ts ./apps/backend/
COPY --from=builder --chown=nextjs:nodejs /app/packages ./packages
COPY --from=builder --chown=nextjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./
COPY --from=builder --chown=nextjs:nodejs /app/pnpm-workspace.yaml ./

# Make /app fully owned by nextjs so pnpm can write temp files
RUN chown -R nextjs:nodejs /app

# Switch into the unprivileged user
USER nextjs

# Install production dependencies
RUN pnpm install --prod

# Install drizzle-kit for migrations
RUN cd apps/backend && pnpm add drizzle-kit@0.31.1

# Copy entrypoint & mark executable
COPY --chown=nextjs:nodejs docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Expose & healthcheck
EXPOSE 12008
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:12008/health || exit 1

# Start both PostgreSQL and MetaMCP
CMD ["./docker-entrypoint.sh"]
