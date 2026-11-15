#!/usr/bin/env bash
# stop-feedback.sh — Stop hook: prompt to save feedback memories when the
# session contained user corrections or confirmed non-obvious approaches.
#
# Claude Code passes hook input as JSON on stdin; the fields used here are
# .transcript_path and .session_id.
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

HOOK_NAME="stop-feedback"
TAG="feedback"
MAX_BLOCKS=1

HOOK_INPUT=$(cat 2>/dev/null || true)
TRANSCRIPT_PATH=$(hook_transcript_path "$HOOK_INPUT")
SESSION_ID=$(hook_session_id "$HOOK_INPUT")

# Gate 1 — loop guard. Cheapest check, and the one that ends the cycle.
# Runs before anything expensive, so an exhausted budget costs no model call.
capture_budget_spent "$TAG" "$TRANSCRIPT_PATH" "$SESSION_ID" "$MAX_BLOCKS" && approve

# Gate 2 — is the input the shape we think it is?
assert_schema "$HOOK_NAME" "$TRANSCRIPT_PATH" || approve

# Gate 3 — is there anything to judge? No genuine user turn means no user
# feedback is possible, by definition.
WINDOW=$(transcript_window "$TRANSCRIPT_PATH" 14 6000)
[[ -n "$WINDOW" ]] || approve
printf '%s' "$WINDOW" | grep -q '^USER: ' || approve

MEMORY=$(memory_index)
MEMORY_SECTION=""
[[ -n "$MEMORY" ]] && MEMORY_SECTION="
Already captured — do not ask for any of this again:
---
$MEMORY
---
"

PROMPT="Review this exchange from a coding session:

---
$WINDOW
---
$MEMORY_SECTION
$CAPTURE_GROUND_RULES

Decide whether the session contains behavioral feedback worth saving to memory.

Return {\"decision\": \"block\", \"reason\": \"This session contains feedback worth capturing. Please save a feedback memory for: <brief description>\"} only if a USER: line shows one of:
- The user corrected the assistant's approach (\"no not that\", \"don't\", \"stop doing X\", \"why didn't you...\")
- The user confirmed a non-obvious approach worked (\"yes exactly\", \"perfect\", accepting an unusual choice)
- The assistant made a claim without evidence and the user called it out
- The user stated a durable preference about workflow, communication style, or tool usage

Return {\"decision\": \"approve\"} if the session was routine, if the point is already
captured above, or if the only evidence is something the ASSISTANT said.

Respond with ONLY the raw JSON object — no markdown, no code fences, no extra text."

RESULT=$(classify "$PROMPT")
DECISION=$(printf '%s' "$RESULT" | sed -n '1p')
REASON=$(printf '%s' "$RESULT" | sed -n '2p')

if [[ "$DECISION" == "block" && -n "$REASON" ]]; then
    capture_budget_record "$TAG" "$SESSION_ID"
    block "$TAG" "$REASON"
fi

approve
