#!/usr/bin/env bash
# stop-insights.sh — Stop hook: prompt to run /project-lore when the session
# contained a non-obvious technical finding.
#
# Claude Code passes hook input as JSON on stdin; the fields used here are
# .transcript_path, .session_id and .last_assistant_message.
#
# Outputs one of:
#   {"decision": "block", "reason": "..."}   — re-prompts Claude with reason
#   {"decision": "approve"}                  — lets the session end
#
# Blocks AT MOST ONCE per session (see hook-lib.sh → capture_budget_spent).
# Deliberately NOT using `set -e`: every failure path must fall through to
# approve so a broken hook can never strand a session.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

HOOK_NAME="stop-insights"
TAG="insights"
MAX_BLOCKS=1

HOOK_INPUT=$(cat 2>/dev/null || true)
TRANSCRIPT_PATH=$(hook_transcript_path "$HOOK_INPUT")
SESSION_ID=$(hook_session_id "$HOOK_INPUT")

# Gate 1 — loop guard, before anything expensive.
capture_budget_spent "$TAG" "$TRANSCRIPT_PATH" "$SESSION_ID" "$MAX_BLOCKS" && approve

# Gate 2 — schema. Skipped when the harness handed us the message directly,
# since that path does not touch the transcript at all.
LAST_MSG=$(hook_last_assistant_message "$HOOK_INPUT")
if [[ -z "$LAST_MSG" ]]; then
    assert_schema "$HOOK_NAME" "$TRANSCRIPT_PATH" || approve
fi

# Gate 3 — build the window. Prefer .last_assistant_message (supplied by the
# harness on Stop) and fall back to deriving it from the transcript.
if [[ -n "$LAST_MSG" ]]; then
    WINDOW="ASSISTANT: $LAST_MSG"
else
    WINDOW=$(transcript_window "$TRANSCRIPT_PATH" 6 6000)
fi
[[ -n "$WINDOW" ]] || approve

MEMORY=$(memory_index)
MEMORY_SECTION=""
[[ -n "$MEMORY" ]] && MEMORY_SECTION="
Already captured — do not ask for any of this again:
---
$MEMORY
---
"

PROMPT="Review this excerpt from a coding session:

---
$WINDOW
---
$MEMORY_SECTION
$CAPTURE_GROUND_RULES

Decide whether the session involved a non-obvious technical finding worth capturing as project lore.

Return {\"decision\": \"block\", \"reason\": \"This session contains insights worth capturing. Please run /project-lore before finishing.\"} if ANY of these are true:
- A hard-to-diagnose failure was resolved
- The fix required knowledge not obvious from the error message or docs
- A counterintuitive framework, tool, or platform limitation was discovered
- Debugging took significant effort or uncovered a surprising root cause

Return {\"decision\": \"approve\"} if the session was routine (reading files, simple
edits, planning, answering questions, minor configuration changes), if the finding
is already captured above, or if the session was itself about capturing memories.

Respond with ONLY the raw JSON object — no markdown, no code fences, no extra text."

RESULT=$(classify "$PROMPT")
DECISION=$(printf '%s' "$RESULT" | sed -n '1p')
REASON=$(printf '%s' "$RESULT" | sed -n '2p')

if [[ "$DECISION" == "block" && -n "$REASON" ]]; then
    capture_budget_record "$TAG" "$SESSION_ID"
    block "$TAG" "$REASON"
fi

approve
