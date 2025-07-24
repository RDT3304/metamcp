#!/bin/sh
set -eu

# ---- Config -----------------------------------------------------------------
: "${PGDATA:=/home/nextjs/pgdata}"
: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=postgres}"
: "${SKIP_MIGRATIONS:=false}"

DATA_DIR="$PGDATA"
LOGFILE="$PGDATA/postgres.log"

# Set database URL for drizzle-kit if not already set
if [ -z "${DATABASE_URL:-}" ]; then
    export DATABASE_URL="postgresql://${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
    echo "🔗 Database URL set to: $DATABASE_URL"
fi

# Also set alternative environment variables that might be expected
export POSTGRES_URL="$DATABASE_URL"
export DB_URL="$DATABASE_URL"

echo "🟢 Starting embedded PostgreSQL…"

# Check if PostgreSQL tools are available
if ! command -v initdb >/dev/null 2>&1; then
    echo "❌ initdb command not found! PostgreSQL tools are not in PATH."
    echo "PATH: $PATH"
    exit 1
fi

# Check if PostgreSQL is already running
if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" 2>/dev/null; then
    echo "PostgreSQL is already running"
else
    # Initialize DB on first run
    if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
        echo "  • initializing database cluster…"
        if ! initdb -D "$DATA_DIR"; then
            echo "❌ Failed to initialize database"
            exit 1
        fi
    fi

    # Start Postgres in background
    echo "  • starting PostgreSQL server…"
    if ! pg_ctl -D "$DATA_DIR" -l "$LOGFILE" start; then
        echo "❌ Failed to start PostgreSQL"
        cat "$LOGFILE" 2>/dev/null || echo "No log file available"
        exit 1
    fi
fi

wait_for_postgres() {
    echo "Waiting for PostgreSQL to be ready..."
    local retries=30
    local count=0
    
    # First wait for any user to connect
    until pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT"; do
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

setup_postgres_user() {
    echo "🔧 Setting up PostgreSQL user and database..."
    
    # Connect as the default user (nextjs) and create postgres user/database
    if ! psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U nextjs -d nextjs -c "SELECT 1;" >/dev/null 2>&1; then
        echo "Creating initial database..."
        createdb -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U nextjs nextjs 2>/dev/null || true
    fi
    
    # Create postgres user if it doesn't exist
    echo "Creating postgres user and database..."
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U nextjs -d nextjs -c "
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'postgres') THEN
                CREATE ROLE postgres WITH LOGIN SUPERUSER;
            END IF;
        END
        \$\$;
    " 2>/dev/null || true
    
    # Create postgres database if it doesn't exist
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U nextjs -d nextjs -c "
        SELECT 'CREATE DATABASE postgres' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'postgres')\gexec
    " 2>/dev/null || true
    
    echo "✅ PostgreSQL user and database setup complete!"
}

run_migrations() {
    if [ "$SKIP_MIGRATIONS" = "true" ]; then
        echo "⚠️  Skipping migrations (SKIP_MIGRATIONS=true)"
        return 0
    fi

    echo "Running database migrations..."
    echo "🔗 Using DATABASE_URL: $DATABASE_URL"
    
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
setup_postgres_user
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
