#!/usr/bin/env bash
# task-completed.sh — TaskCompleted hook: check whether the completed task
# produced architectural decisions worth recording as ADRs, or progressed a
# feature that needs its docs/features/ state updated.
#
# Claude Code passes hook input as JSON on stdin; the fields used here are
# .transcript_path and .session_id.
#
# Outputs one of:
#   {"decision": "block", "reason": "..."}   — re-prompts Claude with reason
#   {"decision": "approve"}                  — lets the task complete
#
# Blocks AT MOST ONCE per session by default. Raise with CAPTURE_MAX_BLOCKS_DOCS
# if you want a nudge on more than the first documented task of a session.
#
# NOTE: TaskCompleted re-prompts are not echoed with the "Stop hook feedback:"
# prefix that the Stop hooks rely on, so the transcript signal does not apply
# here — the session counter file in hook-lib.sh is what enforces the budget.
#
# Deliberately NOT using `set -e`: every failure path must fall through to
# approve so a broken hook can never strand a session.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

HOOK_NAME="task-completed"
TAG="docs"
MAX_BLOCKS="${CAPTURE_MAX_BLOCKS_DOCS:-1}"

HOOK_INPUT=$(cat 2>/dev/null || true)
TRANSCRIPT_PATH=$(hook_transcript_path "$HOOK_INPUT")
SESSION_ID=$(hook_session_id "$HOOK_INPUT")

# Gate 1 — loop guard, before anything expensive.
capture_budget_spent "$TAG" "$TRANSCRIPT_PATH" "$SESSION_ID" "$MAX_BLOCKS" && approve

# Gate 2 — schema.
assert_schema "$HOOK_NAME" "$TRANSCRIPT_PATH" || approve

# Gate 3 — anything to judge?
WINDOW=$(transcript_window "$TRANSCRIPT_PATH" 16 8000)
[[ -n "$WINDOW" ]] || approve

# Which documentation surfaces actually exist in this project.
ROOT="${CLAUDE_PROJECT_DIR:-.}"
HAS_ADR_DIR="false";      [[ -d "$ROOT/docs/adr" ]]        && HAS_ADR_DIR="true"
HAS_FEATURES_DIR="false"; [[ -d "$ROOT/docs/features" ]]   && HAS_FEATURES_DIR="true"
HAS_ROADMAP="false";      [[ -f "$ROOT/docs/ROADMAP.md" ]] && HAS_ROADMAP="true"

# Nothing to update — no point spending a model call.
if [[ "$HAS_ADR_DIR" == "false" && "$HAS_FEATURES_DIR" == "false" && "$HAS_ROADMAP" == "false" ]]; then
    approve
fi

# What is already written down. Without this the hook re-demands documentation
# that exists, every session that touches the same area.
DOCS=$(docs_context)
DOCS_SECTION="Project documentation status:
- docs/adr/ exists: $HAS_ADR_DIR
- docs/features/ exists: $HAS_FEATURES_DIR
- docs/ROADMAP.md exists: $HAS_ROADMAP"
[[ -n "$DOCS" ]] && DOCS_SECTION="$DOCS_SECTION

Already committed — do NOT raise an action for anything covered here:
---
$DOCS
---"

PROMPT="Review this exchange from a coding session where a task was just completed:

---
$WINDOW
---

$DOCS_SECTION

$CAPTURE_GROUND_RULES

Check ALL of the following and collect any that apply into a SINGLE response.
Only raise an action when the document is genuinely absent from the committed
list above — an existing document is not a reason to block.

1. ARCHITECTURAL DECISIONS: Were any significant technical decisions made during this task?
   (framework choices, data model trade-offs, integration strategies, rejected alternatives)
   If yes AND docs/adr/ exists AND no committed ADR already covers this decision:
   note that an ADR should be created.

2. FEATURE PROGRESS: Did this task advance a feature that has (or should have) a document in docs/features/?
   If a committed feature doc exists for it: note it ONLY if this session changed
   something its state checklist does not yet reflect.
   If no committed feature doc exists for it: note that one should be created.

3. ROADMAP ALIGNMENT: If docs/ROADMAP.md exists, was this task aligned with a roadmap item?
   If the roadmap items above already cover this work: do NOT raise a roadmap action.
   Raise one only if the work is genuinely absent from the items shown.

Only flag a surface that actually exists per the status list above.

Return {\"decision\": \"block\", \"reason\": \"<combined list of documentation actions needed>\"} if ANY of the above apply. Be specific about which docs to update.

Return {\"decision\": \"approve\"} if the task was routine with no decisions, no feature progress, and no roadmap gaps.

Respond with ONLY the raw JSON object — no markdown, no code fences, no extra text."

RESULT=$(classify "$PROMPT")
DECISION=$(printf '%s' "$RESULT" | sed -n '1p')
REASON=$(printf '%s' "$RESULT" | sed -n '2p')

if [[ "$DECISION" == "block" && -n "$REASON" ]]; then
    capture_budget_record "$TAG" "$SESSION_ID"
    block "$TAG" "$REASON"
fi

approve
