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

# Initialize DB on first run
if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
  echo "  • initializing database cluster…"
  initdb -D "$DATA_DIR"
fi

# Start Postgres in background
pg_ctl -D "$DATA_DIR" -l "$LOGFILE" start

wait_for_postgres() {
  echo "Waiting for PostgreSQL to be ready..."
  local retries=30
  local count=0
  
  until pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER"; do
    if [ $count -ge $retries ]; then
      echo "❌ PostgreSQL failed to start after $retries attempts"
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
    
    # Check if drizzle-kit is available
    if ! command -v drizzle-kit >/dev/null 2>&1 && ! pnpm exec drizzle-kit --version >/dev/null 2>&1; then
      echo "❌ drizzle-kit not found! Please ensure it's installed."
      echo "💡 You can install it with: pnpm add drizzle-kit"
      exit 1
    fi
    
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

check_service() {
  local pid=$1
  local name=$2
  local port=$3
  
  sleep 3
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "❌ $name server died! Checking logs..."
    return 1
  fi
  
  # Additional health check - try to connect to the port
  if command -v nc >/dev/null 2>&1; then
    if ! nc -z localhost "$port" 2>/dev/null; then
      echo "⚠️  $name server is running but not accepting connections on port $port"
    fi
  fi
  
  echo "✅ $name server started successfully (PID: $pid)"
  return 0
}

# ---- Start sequence ---------------------------------------------------------
wait_for_postgres
run_migrations

# Backend
echo "Starting backend server..."
cd /app/apps/backend
PORT=12009 node dist/index.js &
BACKEND_PID=$!

if ! check_service "$BACKEND_PID" "Backend" "12009"; then
  echo "❌ Backend failed to start properly"
  exit 1
fi

# Frontend
echo "Starting frontend server..."
cd /app/apps/frontend

# Check if pnpm start command exists
if ! pnpm run --silent start --help >/dev/null 2>&1; then
  echo "⚠️  'pnpm start' not available, trying 'pnpm next start'"
  PORT=12008 pnpm next start &
else
  PORT=12008 pnpm start &
fi

FRONTEND_PID=$!

if ! check_service "$FRONTEND_PID" "Frontend" "12008"; then
  echo "❌ Frontend failed to start properly"
  kill "$BACKEND_PID" 2>/dev/null || true
  exit 1
fi

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
echo "📊 Backend running on port 12009"
echo "🌐 Frontend running on port 12008"
echo "🗄️  PostgreSQL running on port 5432"

# Wait for both processes
wait "$BACKEND_PID"
wait "$FRONTEND_PID"
