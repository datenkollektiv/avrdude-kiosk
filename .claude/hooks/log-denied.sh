#!/usr/bin/env bash
set -euo pipefail
# log-denied.sh — PermissionDenied hook: append every denied tool call to
# .claude/logs/denied.jsonl so the user can see what the dontAsk defaultMode
# (or another hook) silently blocked.
#
# Claude Code passes the denial event as JSON on stdin. We wrap it with a
# timestamp and append one line per denial for later inspection — typical
# review with `jq -c '.' .claude/logs/denied.jsonl | tail -20`.

LOG_DIR="${CLAUDE_PROJECT_DIR}/.claude/logs"
LOG_FILE="${LOG_DIR}/denied.jsonl"

mkdir -p "$LOG_DIR"

jq -c '. + {ts: (now | todate)}' >> "$LOG_FILE"
