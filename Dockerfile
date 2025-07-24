# Fixed Dockerfile for RDT3304/metamcp
FROM node:20-slim AS base

# Install pnpm and basic tools
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    postgresql \
    postgresql-client \
    && npm install -g pnpm@10.12.0 drizzle-kit \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy root package files first
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY turbo.json ./

# Create package directories and copy package.json files individually
# This avoids the glob pattern issue that was causing the Turborepo error
COPY apps/frontend/package.json ./apps/frontend/package.json
COPY apps/backend/package.json ./apps/backend/package.json

# Copy the entire packages directory (this avoids glob pattern issues)
COPY packages/ ./packages/

# Install all dependencies (including dev for build)
RUN pnpm install --frozen-lockfile

# Copy source code
COPY . .

# Build the application
RUN pnpm build

# Install only production dependencies and drizzle-kit
RUN pnpm install --prod --ignore-scripts
RUN pnpm add drizzle-kit --save-prod

# Create non-root user
RUN useradd -m -u 1001 nextjs

# Set up PostgreSQL data directory
ENV PGDATA=/home/nextjs/pgdata
RUN mkdir -p $PGDATA /var/run/postgresql \
    && chown -R nextjs:nextjs /home/nextjs $PGDATA /var/run/postgresql

# Copy entrypoint script
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh && chown nextjs:nextjs docker-entrypoint.sh

USER nextjs

EXPOSE 12008 12009

HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:12008/health || curl -f http://localhost:12008/ || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
