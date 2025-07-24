#!/bin/sh
set -eu

# ---- Config -----------------------------------------------------------------
: "${PGDATA:=/home/nextjs/pgdata}"
: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:=postgres}"
: "${SKIP_MIGRATIONS:=false}"

DATA_DIR="$PGDATA"
LOGFILE="$PGDATA/postgres.log"

echo "🟢 Starting embedded PostgreSQL…"

# Check if PostgreSQL is already running
if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" 2>/dev/null; then
  echo "PostgreSQL is already running"
else
  # Initialize DB on first run
  if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
    echo "  • initializing database cluster…"
    initdb -D "$DATA_DIR"
  fi

  # Start Postgres in background
  echo "  • starting PostgreSQL server…"
  pg_ctl -D "$DATA_DIR" -l "$LOGFILE" start
fi

wait_for_postgres() {
  echo "Waiting for PostgreSQL to be ready..."
  local retries=30
  local count=0
  
  until pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER"; do
    if [ $count -ge $retries ]; then
      echo "❌ PostgreSQL failed to start after $retries attempts"
      cat "$LOGFILE" 2>/dev/null || echo "No log file available"
      exit 1
    fi
    echo "PostgreSQL is not ready - sleeping 2 seconds (attempt $((count + 1))/$retries)"
    sleep 2
    count=$((count + 1))
  done
  echo "PostgreSQL is ready!"
}

run_migrations() {
  if [ "$SKIP_MIGRATIONS" = "true" ]; then
    echo "⚠️  Skipping migrations (SKIP_MIGRATIONS=true)"
    return 0
  fi

  echo "Running database migrations..."
  cd /app/apps/backend
  
  if [ -d "drizzle" ] && ls -1 drizzle/*.sql >/dev/null 2>&1; then
    echo "Found migration files, running migrations..."
    
    # Check multiple ways drizzle-kit might be available
    if command -v drizzle-kit >/dev/null 2>&1; then
      drizzle-kit migrate
    elif pnpm exec drizzle-kit --version >/dev/null 2>&1; then
      pnpm exec drizzle-kit migrate
    elif npx drizzle-kit --version >/dev/null 2>&1; then
      npx drizzle-kit migrate
    else
      echo "❌ drizzle-kit not found!"
      echo "Available commands:"
      which pnpm npx node || echo "Basic tools check failed"
      echo "Current directory: $(pwd)"
      echo "Contents: $(ls -la)"
      exit 1
    fi
    
    if [ $? -eq 0 ]; then
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

start_service() {
  local name=$1
  local cmd=$2
  local port=$3
  local dir=$4
  
  echo "Starting $name server..."
  cd "$dir"
  
  eval "$cmd" &
  local pid=$!
  
  sleep 5
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "❌ $name server failed to start!"
    return 1
  fi
  
  echo "✅ $name server started successfully (PID: $pid, Port: $port)"
  return 0
}

# ---- Start sequence ---------------------------------------------------------
wait_for_postgres
run_migrations

# Start backend
if ! start_service "Backend" "PORT=12009 node dist/index.js" "12009" "/app/apps/backend"; then
  echo "❌ Backend startup failed"
  exit 1
fi
BACKEND_PID=$!

# Start frontend
if ! start_service "Frontend" "PORT=12008 pnpm start" "12008" "/app/apps/frontend"; then
  echo "❌ Frontend startup failed"
  kill "$BACKEND_PID" 2>/dev/null || true
  exit 1
fi
FRONTEND_PID=$!

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

echo "🎉 All services started successfully!"
echo "📊 Backend: http://localhost:12009"
echo "🌐 Frontend: http://localhost:12008"
echo "🗄️  PostgreSQL: localhost:5432"

# Wait for both processes
wait "$BACKEND_PID"
wait "$FRONTEND_PID"
