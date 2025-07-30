FROM node:20-slim AS base
# Set PostgreSQL version and PATH
ENV PG_MAJOR=15
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"
ENV PGDATA=/var/lib/postgresql/data
ENV METAMCP_DATA=/app/data

# Install pnpm and basic tools (no global drizzle-kit to avoid version conflicts)
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    postgresql \
    postgresql-client \
    gosu \
    && npm install -g pnpm@10.12.0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy root package files first
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY turbo.json ./

# Copy package files individually to avoid glob issues
COPY apps/frontend/package.json ./apps/frontend/package.json
COPY apps/backend/package.json ./apps/backend/package.json

# Copy the entire packages directory
COPY packages/ ./packages/

# Install all dependencies (including dev for build)
RUN pnpm install --frozen-lockfile

# Copy source code
COPY . .

# Build the application
RUN pnpm build

# Install only production dependencies
RUN pnpm install --prod --ignore-scripts

# Install compatible drizzle versions at workspace root (this fixes the version issue)
RUN pnpm add drizzle-orm drizzle-kit -w

# Create non-root user (but don't switch to it yet)
RUN useradd -m -u 1001 nextjs

# Create directories and set basic permissions (volumes will override ownership)
RUN mkdir -p $METAMCP_DATA /var/run/postgresql /home/nextjs \
    && chown -R nextjs:nextjs /home/nextjs $METAMCP_DATA /var/run/postgresql

# Copy entrypoint script
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Declare volumes for persistent data
VOLUME ["$PGDATA", "$METAMCP_DATA"]

# IMPORTANT: Stay as root - entrypoint will handle user switching
# DO NOT add "USER nextjs" here

EXPOSE 12008 12009

HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:12008/health || curl -f http://localhost:12008/ || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
