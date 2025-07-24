# -----------------------------------------------------------------------------
# Base image with Node & pnpm
# -----------------------------------------------------------------------------
FROM ghcr.io/astral-sh/uv:debian AS base

# Install Node.js 20 + pnpm
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && npm install -g pnpm@10.12.0 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# deps stage – install workspace deps once
# -----------------------------------------------------------------------------
FROM base AS deps
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

# Root manifests
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY turbo.json ./

# Workspace manifests
COPY apps/frontend/package.json                    ./apps/frontend/
COPY apps/backend/package.json                     ./apps/backend/
COPY packages/eslint-config/package.json           ./packages/eslint-config/
COPY packages/trpc/package.json                    ./packages/trpc/
COPY packages/typescript-config/package.json       ./packages/typescript-config/
COPY packages/zod-types/package.json               ./packages/zod-types/

# Install everything (dev + prod) for build
RUN pnpm install --frozen-lockfile

# -----------------------------------------------------------------------------
# builder – compile apps
# -----------------------------------------------------------------------------
FROM base AS builder
WORKDIR /app

# Bring in node_modules and packages from deps
COPY --from=deps /app/node_modules                         ./node_modules
COPY --from=deps /app/apps/frontend/node_modules           ./apps/frontend/node_modules
COPY --from=deps /app/apps/backend/node_modules            ./apps/backend/node_modules
COPY --from=deps /app/packages                             ./packages

# Copy full source
COPY . .

# Build all packages/apps
RUN pnpm build

# -----------------------------------------------------------------------------
# runner – production image
# -----------------------------------------------------------------------------
FROM base AS runner
WORKDIR /app

# --- Versions & paths --------------------------------------------------------
ENV PG_MAJOR=15
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"

# Use a writable PGDATA owned by our non-root user
ENV PGDATA=/home/nextjs/pgdata

# OCI labels
LABEL org.opencontainers.image.source="https://github.com/metatool-ai/metamcp" \
      org.opencontainers.image.description="MetaMCP - aggregates MCP servers into a unified MetaMCP" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.title="MetaMCP" \
      org.opencontainers.image.vendor="metatool-ai"

# Install Postgres server & client + curl (for healthcheck)
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    postgresql \
    postgresql-client \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Create non-root user & group
RUN addgroup --system --gid 1001 nodejs \
 && adduser  --system --uid 1001 --home /home/nextjs nextjs \
 && mkdir -p /home/nextjs/.cache/node/corepack

# Ensure directories Postgres needs exist and are writable
RUN mkdir -p "$PGDATA" /var/run/postgresql \
 && chown -R nextjs:nodejs /home/nextjs "$PGDATA" /var/run/postgresql /var/lib/postgresql

# Copy built output (ownership set directly)
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

# Install only production deps (now writable)
RUN pnpm install --prod --ignore-scripts

# Install drizzle-kit specifically for migrations
RUN pnpm add drizzle-kit --save-prod

# Copy entrypoint & mark executable
COPY --chown=nextjs:nodejs docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Switch to non-root
USER nextjs

# Expose frontend & backend
EXPOSE 12008 12009

# Healthcheck (frontend route) - increased timeout and start period
HEALTHCHECK --interval=30s --timeout=30s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:12008/health || curl -f http://localhost:12008/ || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
