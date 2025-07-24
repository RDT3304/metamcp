#!/bin/sh
set -euo pipefail

# ------------ Config defaults ------------
PGDATA="${PGDATA:-/app/pgdata}"
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"   # superuser created by initdb with -U below

# ------------ Postgres bootstrap ------------
echo "🟢 Starting embedded PostgreSQL…"

# Ensure data dir exists and is owned by us (in case volume mounted)
mkdir -p "$PGDATA"
chmod 700 "$PGDATA"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "  • initializing database cluster in $PGDATA…"
  initdb -D "$PGDATA" -U "$POSTGRES_USER"
fi

# Launch Postgres in background
pg_ctl -D "$PGDATA" -l "$PGDATA/logfile" start

# Wait until Postgres is ready
echo "Waiting for PostgreSQL to be ready..."
until pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" >/dev/null 2>&1; do
  echo "PostgreSQL is not ready - sleeping 2 seconds"
  sleep 2
done
echo "PostgreSQL is ready!"

# ------------ Migrations ------------
echo "Running database migrations..."
cd /app/apps/backend

if [ -d "drizzle" ] && ls -1 drizzle/*.sql >/dev/null 2>&1; then
  echo "Found migration files, running migrations..."
  if pnpm exec drizzle-kit migrate; then
    echo "✅ Migrations completed successfully!"
  else
    echo "❌ Migration failed! Exiting..."
    exit 1
  fi
else
  echo "No migrations found or directory empty"
fi

cd /app

# ------------ Start services ------------
echo "Starting backend server..."
cd /app/apps/backend
PORT=12009 node dist/index.js &
BACKEND_PID=$!

sleep 3
if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
  echo "❌ Backend server died! Exiting..."
  exit 1
fi
echo "✅ Backend server started successfully (PID: $BACKEND_PID)"

echo "Starting frontend server..."
cd /app/apps/frontend
PORT=12008 pnpm start &
FRONTEND_PID=$!

sleep 3
if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then
  echo "❌ Frontend server died! Exiting..."
  kill "$BACKEND_PID" 2>/dev/null || true
  exit 1
fi
echo "✅ Frontend server started successfully (PID: $FRONTEND_PID)"

# ------------ Cleanup & wait ------------
cleanup() {
  echo "Shutting down services..."
  kill "$BACKEND_PID" 2>/dev/null || true
  kill "$FRONTEND_PID" 2>/dev/null || true
  # Stop Postgres gracefully
  pg_ctl -D "$PGDATA" stop -m fast || true
  wait "$BACKEND_PID" 2>/dev/null || true
  wait "$FRONTEND_PID" 2>/dev/null || true
  echo "Services stopped"
}

trap cleanup TERM INT

echo "Services started successfully!"
echo "Backend running on port 12009"
echo "Frontend running on port 12008"

wait "$BACKEND_PID"
wait "$FRONTEND_PID"
