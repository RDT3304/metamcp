#!/bin/sh
set -eu

# ---- Config -----------------------------------------------------------------
: "${PGDATA:=/home/nextjs/pgdata}"
: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:=postgres}"

DATA_DIR="$PGDATA"
LOGFILE="$PGDATA/postgres.log"

echo "🟢 Starting embedded PostgreSQL…"

# Initialize DB on first run
if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
  echo "  • initializing database cluster…"
  initdb -D "$DATA_DIR"
fi

# Start Postgres in background
pg_ctl -D "$DATA_DIR" -l "$LOGFILE" start

wait_for_postgres() {
  echo "Waiting for PostgreSQL to be ready..."
  until pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER"; do
    echo "PostgreSQL is not ready - sleeping 2 seconds"
    sleep 2
  done
  echo "PostgreSQL is ready!"
}

run_migrations() {
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
}

# ---- Start sequence ---------------------------------------------------------
wait_for_postgres
run_migrations

# Backend
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

# Frontend
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

cleanup() {
  echo "Shutting down services..."
  kill "$BACKEND_PID" 2>/dev/null || true
  kill "$FRONTEND_PID" 2>/dev/null || true
  pg_ctl -D "$DATA_DIR" stop -m fast 2>/dev/null || true

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
