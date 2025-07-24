FROM node:20-slim AS base

# Set PostgreSQL version and PATH
ENV PG_MAJOR=15
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"
ENV PGDATA=/home/nextjs/pgdata

# Install pnpm and basic tools (including drizzle-kit globally)
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

# Copy package files individually to avoid glob issues
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

# Install only production dependencies
RUN pnpm install --prod --ignore-scripts

# Create non-root user
RUN useradd -m -u 1001 nextjs

# Set up PostgreSQL data directory (PGDATA already set above)
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
