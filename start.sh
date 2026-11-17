#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXT_PORT="${NEXT_PORT:-3000}"
NLP_PORT="${NLP_PORT:-8000}"
ESB_PORT="${ESB_PORT:-8081}"

validate_port() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    printf 'Error: %s must be a TCP port between 1 and 65535 (got %s).\n' "$name" "$value" >&2
    exit 2
  fi
}

port_is_in_use() {
  command -v lsof >/dev/null 2>&1 &&
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

next_available_port() {
  local port="$1"
  while port_is_in_use "$port"; do
    if (( port >= 65535 )); then
      printf 'Error: no available TCP port found after %s.\n' "$1" >&2
      exit 1
    fi
    port=$((port + 1))
  done
  printf '%s' "$port"
}

usage() {
  printf 'Usage: %s\n' "$0"
  printf 'Starts the Python NLP service, required Apache Camel ESB, and Next.js app.\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

cd "$ROOT_DIR"
validate_port "NEXT_PORT" "$NEXT_PORT"
validate_port "NLP_PORT" "$NLP_PORT"
validate_port "ESB_PORT" "$ESB_PORT"

for command_name in node npm curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required. Install Node.js 20+, npm, and curl first.\n' "$command_name" >&2
    exit 1
  fi
done

if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'; then
  printf 'Error: Node.js 20+ is required.\n' >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  printf 'Error: .env is missing. Copy .env.example to .env and set DATABASE_URL first.\n' >&2
  exit 1
fi

if [[ ! -d node_modules ]]; then
  printf 'Installing Node.js dependencies...\n'
  npm ci
fi

PYTHON_CMD=""
for candidate in python3.13 python3.12 python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1 &&
    "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
    PYTHON_CMD="$candidate"
    break
  fi
done
if [[ -z "$PYTHON_CMD" ]]; then
  printf 'Error: Python 3.11+ is required to run the NLP service and ESB.\n' >&2
  exit 1
fi

NLP_PYTHON="$ROOT_DIR/nlp-service/.venv/bin/python"
# Keep this check in sync with the imports performed during app startup.
# Existing virtual environments may predate the LangGraph migration.
if [[ ! -x "$NLP_PYTHON" ]] || ! "$NLP_PYTHON" -c 'import fastapi, faiss, gensim, sklearn, uvicorn, yfinance, langchain_core, langgraph' >/dev/null 2>&1; then
  printf 'Preparing Python NLP environment (first run may take several minutes)...\n'
  "$PYTHON_CMD" -m venv "$ROOT_DIR/nlp-service/.venv"
  "$NLP_PYTHON" -m pip install -r "$ROOT_DIR/nlp-service/requirements.txt"
fi

if ! command -v java >/dev/null 2>&1; then
  printf 'Error: Java 17+ is required to run the Apache Camel ESB.\n' >&2
  exit 1
fi
if [[ ! -f "$ROOT_DIR/esb/mvnw" ]]; then
  printf 'Error: the required ESB Maven wrapper is missing from esb/.\n' >&2
  exit 1
fi
if ! java -version 2>&1 | grep -Eq 'version "(1[7-9]|[2-9][0-9])'; then
  printf 'Error: Java 17+ is required to run the Apache Camel ESB.\n' >&2
  exit 1
fi
if ! command -v bash >/dev/null 2>&1; then
  printf 'Error: bash is required to run the ESB Maven wrapper.\n' >&2
  exit 1
fi

printf 'Generating Prisma client...\n'
npm exec -- prisma generate

pids=()
cleanup() {
  status=$?
  trap - EXIT INT TERM
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

NLP_SERVICE_BASE_URL="http://127.0.0.1:${NLP_PORT}"
NLP_PORT_REQUESTED="$NLP_PORT"
NLP_PORT="$(next_available_port "$NLP_PORT")"
if [[ "$NLP_PORT" != "$NLP_PORT_REQUESTED" ]]; then
  printf 'NLP port is occupied; using port %s.\n' "$NLP_PORT"
fi
printf 'Starting Python NLP service at http://localhost:%s...\n' "$NLP_PORT"
(
  cd "$ROOT_DIR/nlp-service"
  exec "$NLP_PYTHON" -m uvicorn app.main:app --host 127.0.0.1 --port "$NLP_PORT"
) &
NLP_PID=$!
pids+=("$NLP_PID")

NLP_READY=false
for _ in {1..30}; do
  if curl --silent --fail "http://127.0.0.1:${NLP_PORT}/health" >/dev/null; then
    NLP_READY=true
    break
  fi
  if ! kill -0 "$NLP_PID" 2>/dev/null; then
    wait "$NLP_PID" || true
    printf 'Error: Python NLP service exited before becoming ready.\n' >&2
    exit 1
  fi
  sleep 1
done
if [[ "$NLP_READY" != true ]]; then
  printf 'Error: Python NLP service did not become ready at http://localhost:%s.\n' "$NLP_PORT" >&2
  exit 1
fi

ESB_PORT_REQUESTED="$ESB_PORT"
ESB_PORT="$(next_available_port "$ESB_PORT")"
if [[ "$ESB_PORT" != "$ESB_PORT_REQUESTED" ]]; then
  printf 'ESB port is occupied; using port %s.\n' "$ESB_PORT"
fi
printf 'Starting required Apache Camel ESB at http://localhost:%s...\n' "$ESB_PORT"
(
  cd "$ROOT_DIR/esb"
  export NLP_SERVICE_TARGET_URL="http://127.0.0.1:${NLP_PORT}"
  export ESB_PORT
  exec bash ./mvnw spring-boot:run
) &
ESB_PID=$!
pids+=("$ESB_PID")

ESB_READY=false
for _ in {1..90}; do
  if curl --silent --fail --max-time 5 \
    "http://127.0.0.1:${ESB_PORT}/ready" >/dev/null; then
    ESB_READY=true
    break
  fi
  if ! kill -0 "$ESB_PID" 2>/dev/null; then
    wait "$ESB_PID" || true
    printf 'Error: Apache Camel ESB exited before becoming ready.\n' >&2
    exit 1
  fi
  sleep 1
done
if [[ "$ESB_READY" != true ]]; then
  printf 'Error: Apache Camel ESB did not become ready at http://localhost:%s.\n' "$ESB_PORT" >&2
  exit 1
fi
NLP_SERVICE_BASE_URL="http://127.0.0.1:${ESB_PORT}"

printf 'Starting PulseWatch on port %s...\n' "$NEXT_PORT"
NEXT_PORT="$(next_available_port "$NEXT_PORT")"
NLP_SERVICE_URL="$NLP_SERVICE_BASE_URL" npm run dev -- --hostname 127.0.0.1 --port "$NEXT_PORT" &
NEXT_PID=$!
pids+=("$NEXT_PID")

NEXT_READY=false
for _ in {1..60}; do
  # Warm the protected dashboard and public login route. The dashboard warm-up
  # compiles app/page.js before a browser can receive a document referencing it.
  if curl --silent --show-error --fail --max-time 5 \
    -H 'Cookie: pw_session=startup-warmup' \
    "http://127.0.0.1:${NEXT_PORT}/" >/dev/null &&
    curl --silent --show-error --fail --max-time 5 \
    "http://127.0.0.1:${NEXT_PORT}/login" >/dev/null &&
    curl --silent --show-error --fail --max-time 5 \
    "http://127.0.0.1:${NEXT_PORT}/chat" >/dev/null; then
    NEXT_READY=true
    break
  fi
  if ! kill -0 "$NEXT_PID" 2>/dev/null; then
    wait "$NEXT_PID" || true
    printf 'Error: Next.js exited before becoming ready.\n' >&2
    exit 1
  fi
  sleep 1
done
if [[ "$NEXT_READY" != true ]]; then
  printf 'Error: PulseWatch did not become ready at http://localhost:%s.\n' "$NEXT_PORT" >&2
  exit 1
fi

printf '\nPulseWatch is ready. Open these links:\n'
printf '  App:       http://localhost:%s/\n' "$NEXT_PORT"
printf '  ESB health: http://localhost:%s/health\n' "$ESB_PORT"
printf '  ESB ready:  http://localhost:%s/ready\n' "$ESB_PORT"
printf '  NLP docs:   http://localhost:%s/docs\n' "$ESB_PORT"
printf 'Press Ctrl+C to stop the services.\n\n'

while kill -0 "$NEXT_PID" 2>/dev/null; do
  if ! kill -0 "$NLP_PID" 2>/dev/null; then
    wait "$NLP_PID" || true
    printf 'Error: Python NLP service stopped unexpectedly.\n' >&2
    exit 1
  fi
  if ! kill -0 "$ESB_PID" 2>/dev/null; then
    wait "$ESB_PID" || true
    printf 'Error: Apache Camel ESB stopped unexpectedly.\n' >&2
    exit 1
  fi
  sleep 1
done

wait "$NEXT_PID"
