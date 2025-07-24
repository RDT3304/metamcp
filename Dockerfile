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

# deps stage
FROM base AS deps
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY turbo.json ./

COPY apps/frontend/package.json ./apps/frontend/
COPY apps/backend/package.json  ./apps/backend/
COPY packages/eslint-config/package.json ./packages/eslint-config/
COPY packages/trpc/package.json        ./packages/trpc/
COPY packages/typescript-config/package.json ./packages/typescript-config/
COPY packages/zod-types/package.json   ./packages/zod-types/

RUN pnpm install --frozen-lockfile

# builder stage
FROM base AS builder
WORKDIR /app

COPY --from=deps /app/node_modules           ./node_modules
COPY --from=deps /app/apps/frontend/node_modules ./apps/frontend/node_modules
COPY --from=deps /app/apps/backend/node_modules  ./apps/backend/node_modules
COPY --from=deps /app/packages            ./packages

COPY . .
RUN pnpm build

# production runner
FROM base AS runner
WORKDIR /app

LABEL org.opencontainers.image.source="https://github.com/metatool-ai/metamcp"
LABEL org.opencontainers.image.description="MetaMCP - aggregates MCP servers into a unified MetaMCP"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="MetaMCP"
LABEL org.opencontainers.image.vendor="metatool-ai"

RUN apt-get update && apt-get install -y \
    curl \
    postgresql \
    postgresql-client \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# initdb as postgres
USER postgres
RUN /usr/lib/postgresql/15/bin/initdb -D /var/lib/postgresql/data

# back to root for setup
USER root

# create non‑root user
RUN addgroup --system --gid 1001 nodejs \
 && adduser --system --uid 1001 --home /home/nextjs nextjs \
 && mkdir -p /home/nextjs/.cache/node/corepack \
 && chown -R nextjs:nodejs /home/nextjs

# bring in built artifacts & node_modules
COPY --from=builder --chown=root:root /app/apps/frontend/.next      ./apps/frontend/.next
COPY --from=builder --chown=root:root /app/apps/frontend/package.json ./apps/frontend/
COPY --from=builder --chown=root:root /app/apps/backend/dist     ./apps/backend/dist
COPY --from=builder --chown=root:root /app/apps/backend/package.json  ./apps/backend/
COPY --from=builder --chown=root:root /app/apps/backend/drizzle    ./apps/backend/drizzle
COPY --from=builder --chown=root:root /app/apps/backend/drizzle.config.ts ./apps/backend/
COPY --from=builder --chown=root:root /app/packages             ./packages
COPY --from=builder --chown=root:root /app/package.json          ./
COPY --from=builder --chown=root:root /app/pnpm-workspace.yaml    ./
COPY --from=builder --chown=root:root /app/node_modules          ./node_modules

# install prod‑only deps + drizzle‑kit, *as root* so pnpm store stays consistent
RUN pnpm install --prod \
 && cd apps/backend && pnpm add drizzle-kit@0.31.1

# fix ownership
RUN chown -R nextjs:nodejs /app

USER nextjs

# entrypoint & ports
COPY --chown=nextjs:nodejs docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

EXPOSE 12008
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:12008/health || exit 1

CMD ["./docker-entrypoint.sh"]
