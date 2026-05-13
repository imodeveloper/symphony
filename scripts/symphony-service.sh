#!/bin/zsh
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_DIR="/Users/ivan.borinschi/Work/CodexOrchestrator"
ELIXIR_DIR="$APP_DIR/elixir"
DATA_DIR="$APP_DIR/data"
LOG_DIR="$DATA_DIR/logs"
SERVICE_LOG="$LOG_DIR/service.log"
WORKFLOW="$ELIXIR_DIR/WORKFLOW.md"
PORT="${SYMPHONY_PORT:-4174}"
KEYCHAIN_SERVICE="${SYMPHONY_KEYCHAIN_SERVICE:-codex-orchestrator-linear}"
KEYCHAIN_ACCOUNT="${SYMPHONY_KEYCHAIN_ACCOUNT:-LINEAR_API_KEY}"

mkdir -p "$LOG_DIR"

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  LINEAR_API_KEY="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null || true)"
  export LINEAR_API_KEY
fi

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  {
    print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ') missing LINEAR_API_KEY"
    print -r -- "Store the key with: security add-generic-password -U -s '$KEYCHAIN_SERVICE' -a '$KEYCHAIN_ACCOUNT' -w '<redacted>'"
  } >> "$SERVICE_LOG"
  exit 78
fi

cd "$ELIXIR_DIR"
exec mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$LOG_DIR" \
  --port "$PORT" \
  "$WORKFLOW" >> "$SERVICE_LOG" 2>&1
