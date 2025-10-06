#!/usr/bin/env bash
# Test script for Weather Summary API endpoints
# Usage:
#   ./test_endpoints.sh            # uses default BASE_URL http://127.0.0.1:8000
#   ./test_endpoints.sh --prod      # test production deployment
#   ./test_endpoints.sh --local     # explicitly test local server
#   BASE_URL=<custom-url> ./test_endpoints.sh  # test custom deployment
#   NO_START=1 ./test_endpoints.sh  # don't attempt to start local server

set -u

# Deployment URLs
LOCAL_URL="http://127.0.0.1:8000"
PROD_URL="https://ai-weather-summary.onrender.com"

# Parse command line arguments
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --prod)
        export BASE_URL="$PROD_URL"
        export NO_START=1  # Don't start local server when testing prod
        return 0
        ;;
      --local)
        export BASE_URL="$LOCAL_URL"
        return 0
        ;;
      --help)
        printf "Usage:\n"
        printf "  ./test_endpoints.sh            # test local server\n"
        printf "  ./test_endpoints.sh --prod     # test production deployment\n"
        printf "  ./test_endpoints.sh --local    # explicitly test local\n"
        printf "  BASE_URL=<url> ./test_endpoints.sh  # test custom deployment\n"
        exit 0
        ;;
    esac
  done
  return 0
}

# Process arguments
parse_args "$@"

# Security checks
check_env_security() {
  local env_file=".env"
  if [ -f "$env_file" ]; then
    local perms
    perms=$(stat -f "%Lp" "$env_file" 2>/dev/null || stat -c "%a" "$env_file" 2>/dev/null)
    if [ "$perms" != "600" ]; then
      printf "\nWARNING: .env file permissions are not secure (found: %s, expected: 600)\n" "$perms"
      printf "Run: chmod 600 .env\n\n"
    fi
  fi
}

# Environment validation
validate_environment() {
  if [ ! -f ".env" ]; then
    printf "ERROR: .env file not found. Please create it with your API key.\n"
    return 1
  fi
  
  if [ ! -f "requirements.txt" ]; then
    printf "ERROR: requirements.txt not found. Please ensure you're in the correct directory.\n"
    return 1
  fi
}

BASE_URL=${BASE_URL:-http://127.0.0.1:8000}
PID_FILE=".test_server_pid"
LOG_FILE=".test_server.log"

# Run security checks
check_env_security

# Validate environment
validate_environment || exit 1

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

pretty_print() {
  local body="$1"
  if has_cmd jq; then
    echo "$body" | jq . 2>/dev/null || echo "$body"
  else
    echo "$body"
  fi
}

do_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local check_summary="${4:-}"  # Optional: validate summary response

  printf "\n==> %s %s\n" "$method" "$path"
  if [ -n "$data" ]; then
    printf "Request JSON: %s\n" "$data"
  fi

  # Append status code on a new line for easy parsing
  local resp
  if [ -n "$data" ]; then
    resp=$(curl -sk -H "Content-Type: application/json" -X "$method" "$BASE_URL$path" -d "$data" -w "\n%{http_code}")
  else
    resp=$(curl -sk -X "$method" "$BASE_URL$path" -w "\n%{http_code}")
  fi

  local status=$(echo "$resp" | tail -n1)
  local body=$(echo "$resp" | sed '$d')

  printf "HTTP status: %s\n" "$status"
  if [ -n "$body" ]; then
    printf "Body:\n"
    pretty_print "$body"
    
    # For weather-summary endpoint, validate response format
    if [ "$check_summary" = "1" ] && [ "$status" = "200" ]; then
      # Check if response contains only summary field
      if ! echo "$body" | jq -e 'if type == "object" then keys == ["summary"] and (.summary | type == "string") else false end' >/dev/null; then
        printf "ERROR: Invalid response format. Expected only {\"summary\": \"string\"}\n"
        return 1
      fi
      printf "✓ Response format valid (contains only summary field)\n"
    fi
  else
    printf "(empty body)\n"
  fi

  # Return non-zero if status is not 2xx
  case "$status" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

start_server_bg() {
  if [ "${NO_START:-0}" = "1" ]; then
    printf "NO_START=1 — not attempting to start the server.\n"
    return 1
  fi

  # Check for existing process
  if [ -f "$PID_FILE" ]; then
    local old_pid
    old_pid=$(cat "$PID_FILE")
    if ps -p "$old_pid" >/dev/null 2>&1; then
      printf "WARNING: Server already running with PID %s\n" "$old_pid"
      return 0
    else
      rm -f "$PID_FILE"
    fi
  fi

  if has_cmd python3; then
    PY=python3
  elif has_cmd python; then
    PY=python
  else
    echo "No python or python3 found in PATH; cannot start server automatically." >&2
    return 2
  fi

  echo "Attempting to start server with: $PY -m uvicorn main:app --host 127.0.0.1 --port 8000"
  # Start in background and capture PID
  ( $PY -m uvicorn main:app --host 127.0.0.1 --port 8000 > /dev/null 2>&1 & )
  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Server started (pid $pid). Waiting for health endpoint..."

  # wait up to 30 seconds for server to become healthy (longer for cloud deployments)
  for i in {1..30}; do
    sleep 1
    code=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/health" || echo "000")
    if [ "$code" = "200" ]; then
      echo "Server is healthy."
      return 0
    fi
    printf "."
    if [ $((i % 10)) -eq 0 ]; then
      printf " %ds\n" "$i"
    fi
  done

  echo "Server did not respond to /health within timeout." >&2
  return 3
}

# Cleanup function for proper server shutdown
cleanup_started_server() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
      printf "Stopping server (pid %s)...\\n" "$pid"
      kill "$pid"
      
      # Wait for process to stop
      local i
      for i in {1..5}; do
        if ! ps -p "$pid" >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      
      # Force kill if still running
      if ps -p "$pid" >/dev/null 2>&1; then
        printf "Server still running, forcing shutdown...\\n"
        kill -9 "$pid" || printf "Failed to force kill pid %s\\n" "$pid"
      fi
    fi
    rm -f "$PID_FILE"
  fi
  # Clean up log file
  [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"
}

# Set up trap for cleanup on script exit
trap cleanup_started_server EXIT

echo "Testing API at: $BASE_URL"

# Check basic connectivity
health_code=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/health" || echo "000")
if [ "$health_code" != "200" ]; then
  echo "Health check returned $health_code."
  start_server_bg || echo "Continuing without starting server. Some tests may fail."
else
  echo "Server already running (health OK)."
fi

echo "\nRunning endpoint tests..."

# 1) GET /
do_request GET "/"

# 2) GET /health
do_request GET "/health"

# 3) POST /weather-summary (valid payload, check summary format)
VALID_PAYLOAD='{"latitude":37.7749, "longitude":-122.4194}'
do_request POST "/weather-summary" "$VALID_PAYLOAD" "1"

# 4) POST /weather-summary (invalid latitude -> validation error expected)
INVALID_LAT='{"latitude":100.0, "longitude":0.0}'
do_request POST "/weather-summary" "$INVALID_LAT"

# 5) POST /weather-summary (missing field -> validation error expected)
MISSING_FIELD='{"latitude":45.0}'
do_request POST "/weather-summary" "$MISSING_FIELD"

printf "\n======================\nTest Summary\n======================\n"
printf "Total Tests Run: 5\n"
printf "Failed Tests: %s\n" "$FAILURES"
if [ "$FAILURES" -eq 0 ]; then
  printf "✅ All tests passed!\n"
else
  printf "❌ Some tests failed\n"
fi
printf "======================\n"

# If we started the server, offer to stop it
if [ -f "$PID_FILE" ]; then
  echo "\nThis script started a server (pid in $PID_FILE). To stop it now run:"
  echo "  kill $(cat $PID_FILE)"
  echo "Or run: ./test_endpoints.sh --stop to automatically stop it."
fi

if [ "${1:-}" = "--stop" ]; then
  cleanup_started_server
fi

exit 0
