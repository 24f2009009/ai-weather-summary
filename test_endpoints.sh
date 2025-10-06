#!/usr/bin/env bash
# Test script for Weather Summary API endpoints
# Usage:
#   ./test_endpoints.sh            # uses default BASE_URL http://127.0.0.1:8000
#   BASE_URL=http://localhost:8000 ./test_endpoints.sh
#   NO_START=1 ./test_endpoints.sh  # don't attempt to start the server if down

set -u

BASE_URL=${BASE_URL:-http://127.0.0.1:8000}
PID_FILE=".test_server_pid"

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
    resp=$(curl -s -H "Content-Type: application/json" -X "$method" "$BASE_URL$path" -d "$data" -w "\n%{http_code}")
  else
    resp=$(curl -s -X "$method" "$BASE_URL$path" -w "\n%{http_code}")
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
    echo "NO_START=1 — not attempting to start the server."
    return 1
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

  # wait up to 12 seconds for server to become healthy
  for i in {1..12}; do
    sleep 1
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health" || echo "000")
    if [ "$code" = "200" ]; then
      echo "Server is healthy."
      return 0
    fi
  done

  echo "Server did not respond to /health within timeout." >&2
  return 3
}

cleanup_started_server() {
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
      echo "Stopping server started by this script (pid $pid)..."
      kill "$pid" || echo "Failed to kill pid $pid"
    fi
    rm -f "$PID_FILE"
  fi
}

echo "Testing API at: $BASE_URL"

# Check basic connectivity
health_code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health" || echo "000")
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

echo "\nTests finished."

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
