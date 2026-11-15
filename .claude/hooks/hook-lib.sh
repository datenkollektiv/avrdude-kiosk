# shellcheck shell=bash
# hook-lib.sh — shared helpers for the capture hooks (stop-feedback,
# stop-insights, task-completed and friends).
#
# Source it from a sibling hook with a self-locating path, so it survives
# session cwd drift (see docs/project-lore.md → Hooks):
#
#   source "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"
#
# Everything here fails OPEN. A capture hook must never be able to trap a
# session, so any unreadable input, malformed JSON, or missing tool results
# in `approve`, never in a block.
#
# ---------------------------------------------------------------------------
# Why this library exists
# ---------------------------------------------------------------------------
# The first generation of these hooks shared four silent contract mismatches
# against the harness. All four are fixed here, once, for every caller:
#
#   1. No loop terminator. They documented `stop_hook_active` in a comment and
#      read it in none. That field is NOT part of the Stop payload — reading it
#      would yield `false` forever. `capture_budget_spent` counts real evidence
#      from the transcript instead.
#   2. The role filter was '"role":"(assistant|human)"'. Transcripts use
#      "user"; "human" never appears. The classifier only ever saw the
#      assistant's own text, and read it back as user intent.
#   3. A naive fix to (2) is WORSE: the harness delivers each block reason back
#      as a `type:"user"` message. Admitting those makes the loop self-
#      confirming — the hook reads its own demand as a user request. Genuine
#      turns must be selected structurally (`isMeta`/`toolUseResult`), never by
#      a grep over the raw line.
#   4. `tail -N` counted JSONL lines, not turns, so tool-heavy sessions yielded
#      a near-empty window. `transcript_window` counts turns.

# --- decisions -------------------------------------------------------------

approve() {
    printf '{"decision":"approve"}\n'
    exit 0
}

# block <tag> <reason>
# The tag is embedded in the reason so a later invocation in the same session
# can count how many times THIS hook has already blocked. Keep tags stable —
# `capture_budget_spent` matches on them.
block() {
    local tag="$1" reason="$2"
    jq -cn --arg r "[$tag] $reason" '{decision:"block", reason:$r}'
    exit 0
}

# --- input -----------------------------------------------------------------

hook_transcript_path() {
    printf '%s' "${1:-}" | jq -r '.transcript_path // ""' 2>/dev/null || true
}

hook_session_id() {
    local id
    id=$(printf '%s' "${1:-}" | jq -r '.session_id // ""' 2>/dev/null || true)
    [[ -n "$id" ]] || id="${CLAUDE_SESSION_ID:-}"
    printf '%s' "${id:-none}"
}

# Final assistant text of the turn. The harness supplies this directly on Stop
# and SubagentStop, which is cheaper and more accurate than re-deriving it.
hook_last_assistant_message() {
    printf '%s' "${1:-}" | jq -r '.last_assistant_message // ""' 2>/dev/null || true
}

# --- loop guard ------------------------------------------------------------
#
# Two independent signals, whichever fires first:
#
#   * transcript — every block comes back as an isMeta user message prefixed
#     "Stop hook feedback: ", carrying our reason (and therefore our tag)
#     verbatim. This is exact, needs no session id, and cannot go stale.
#   * counter file — a backstop keyed on the session id, in case the harness
#     changes how it echoes block reasons.

# Ceiling on capture blocks from ALL hooks combined, per session. Without this,
# four hooks each honouring a private budget of 1 still cost four extra turns.
CAPTURE_GLOBAL_MAX="${CAPTURE_GLOBAL_MAX:-2}"

# _count_block_reasons <transcript_path> [tag]
# Counts harness-echoed block re-prompts, optionally only this hook's.
_count_block_reasons() {
    local transcript="$1" tag="${2:-}" n
    [[ -f "$transcript" ]] || { printf '0'; return 0; }
    n=$(jq -r --arg tag "$tag" '
        select(.type == "user" and .isMeta == true)
        | (.message.content? // empty
           | if type == "string" then . else (map(select(.type == "text")) | map(.text) | join(" ")) end)
        | select(startswith("Stop hook feedback:"))
        | select($tag == "" or contains("[" + $tag + "]"))
    ' "$transcript" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# capture_budget_spent <tag> <transcript_path> <session_id> <max>
# Returns 0 (success) when the budget is EXHAUSTED — i.e. do not block again.
capture_budget_spent() {
    local tag="$1" transcript="$2" session="$3" max="$4"
    local mine file_count total

    mine=$(_count_block_reasons "$transcript" "$tag")

    local counter; counter=$(_capture_counter_file "$tag" "$session")
    file_count=0
    [[ -f "$counter" ]] && file_count=$(tr -dc '0-9' <"$counter" 2>/dev/null || printf '0')
    [[ -n "$file_count" ]] || file_count=0
    (( file_count > mine )) && mine="$file_count"

    # This hook's own budget.
    (( mine >= max )) && return 0

    # The all-hooks ceiling.
    total=$(_count_block_reasons "$transcript")
    (( total >= CAPTURE_GLOBAL_MAX ))
}

# capture_budget_record <tag> <session_id> — call immediately before blocking.
capture_budget_record() {
    local counter n=0
    counter=$(_capture_counter_file "$1" "$2")
    [[ -f "$counter" ]] && n=$(tr -dc '0-9' <"$counter" 2>/dev/null || echo 0)
    [[ -n "$n" ]] || n=0
    printf '%s' "$(( n + 1 ))" >"$counter" 2>/dev/null || true
}

_capture_counter_file() {
    printf '%s/cc-capture-%s-%s' "${TMPDIR:-/tmp}" "$1" "$2"
}

# --- transcript ------------------------------------------------------------

# transcript_window <transcript_path> <max_turns> [max_bytes]
#
# Emits one line per GENUINE turn, oldest first, each labelled "USER:" or
# "ASSISTANT:". Excluded: tool results, system/meta injections, and every
# hook-injected re-prompt. Whitespace is collapsed so one turn is exactly one
# line, which is what makes <max_turns> a turn count rather than a line count.
#
# The explicit role labels are load-bearing: they are what lets the classifier
# tell a user's stated preference from the assistant's own prose.
transcript_window() {
    local transcript="$1" max_turns="${2:-12}" max_bytes="${3:-6000}"
    [[ -f "$transcript" ]] || return 0

    jq -r '
        select(.type == "user" or .type == "assistant")
        | select(.isMeta != true)
        | select(has("toolUseResult") | not)
        | {
            role: (.message.role? // ""),
            text: (.message.content? // empty
                   | if type == "string" then .
                     else (map(select(.type == "text")) | map(.text) | join("\n"))
                     end)
          }
        | select(.role == "user" or .role == "assistant")
        | select((.text // "") | test("\\S"))
        | select(.text | startswith("Stop hook feedback:") | not)
        | (if .role == "user" then "USER: " else "ASSISTANT: " end)
          + ((.text | gsub("\\s+"; " "))[0:700])
    ' "$transcript" 2>/dev/null \
        | tail -n "$max_turns" \
        | tail -c "$max_bytes" || true
}

# transcript_has_user_turn <transcript_path> — genuine human turn present?
transcript_has_user_turn() {
    transcript_window "$1" 200 200000 2>/dev/null | grep -q '^USER: '
}

# transcript_window_with_tools <transcript_path> <max_turns> [max_bytes]
#
# As transcript_window, but also surfaces Bash commands and Read paths. Use for
# verification hooks that must judge what was actually RUN, not just what was
# claimed — the claim is exactly the thing under suspicion.
transcript_window_with_tools() {
    local transcript="$1" max_turns="${2:-20}" max_bytes="${3:-6000}"
    [[ -f "$transcript" ]] || return 0

    jq -r '
        select(.type == "user" or .type == "assistant")
        | select(.isMeta != true)
        | select(has("toolUseResult") | not)
        | {
            role: (.message.role? // ""),
            text: (.message.content? // empty
                   | if type == "string" then .
                     else (map(
                            if .type == "text" then .text
                            elif .type == "tool_use" and .name == "Bash" then "[Bash] " + (.input.command // "")
                            elif .type == "tool_use" and .name == "Read" then "[Read] " + (.input.file_path // "")
                            else empty end
                          ) | join("\n"))
                     end)
          }
        | select(.role == "user" or .role == "assistant")
        | select((.text // "") | test("\\S"))
        | select(.text | startswith("Stop hook feedback:") | not)
        | (if .role == "user" then "USER: " else "ASSISTANT: " end)
          + ((.text | gsub("\\s+"; " "))[0:900])
    ' "$transcript" 2>/dev/null \
        | tail -n "$max_turns" \
        | tail -c "$max_bytes" || true
}

# --- schema assertion ------------------------------------------------------
#
# Every defect this library fixes was a SILENT shape mismatch against the
# harness. When the shape stops matching again, say so on stderr instead of
# quietly grading nothing.

# assert_schema <hook_name> <transcript_path> — non-zero means "do not proceed".
assert_schema() {
    local name="$1" transcript="$2"

    if [[ -z "$transcript" ]]; then
        printf '%s: hook payload had no .transcript_path — approving.\n' "$name" >&2
        return 1
    fi
    if [[ ! -f "$transcript" ]]; then
        printf '%s: transcript %s not readable — approving.\n' "$name" "$transcript" >&2
        return 1
    fi
    if ! grep -q '"role":"user"' "$transcript" 2>/dev/null; then
        printf '%s: no "role":"user" in transcript — schema may have changed, approving.\n' "$name" >&2
        return 1
    fi
    return 0
}

# --- memory ----------------------------------------------------------------

# memory_index — the already-captured index, for idempotency. Emits nothing
# when no store exists, in which case callers simply skip the "already covered"
# rule rather than asserting an empty store.
#
# Hard-bounded on purpose. A mature project's index runs to tens of KB (124
# entries / 50 KB in maker-parts), and injecting it whole pushed `claude -p`
# past the hook's 30 s timeout — at which point the harness kills the hook and
# the check silently never runs. Titles are enough to recognise "already
# covered"; the assistant re-checks the store properly before writing anyway.
MEMORY_INDEX_MAX_BYTES="${MEMORY_INDEX_MAX_BYTES:-4000}"

memory_index() {
    local root="${CLAUDE_PROJECT_DIR:-.}" index="" total
    [[ -f "$root/memory/MEMORY.md" ]] || return 0

    index=$(LC_ALL=C grep '^- ' "$root/memory/MEMORY.md" 2>/dev/null | cut -c1-110)
    [[ -n "$index" ]] || return 0

    total=$(printf '%s' "$index" | wc -c | tr -d ' ')
    if (( total > MEMORY_INDEX_MAX_BYTES )); then
        printf '%s\n' "$index" | head -c "$MEMORY_INDEX_MAX_BYTES"
        printf '\n(index truncated — absence from this list does NOT prove a topic is uncaptured)\n'
    else
        printf '%s\n' "$index"
    fi
    return 0
}

# --- documentation ---------------------------------------------------------

# docs_context — what documentation ALREADY exists, so the classifier does not
# demand a doc that is sitting in the repo. Same idempotency job memory_index
# does for the two Stop hooks: without it, task-completed re-raises "write an
# ADR for this" on every session that touches an already-decided area.
#
# Tracked files only (`git ls-files`), which is the question actually being
# asked — "is this written down and committed" — and conveniently ignores build
# output and scratch drafts. Outside a git repo it emits nothing and the caller
# falls back to bare existence flags.
#
# Bounded for the same reason as MEMORY_INDEX_MAX_BYTES: a mature ROADMAP.md is
# tens of KB, and injecting it whole pushes `claude -p` past the 30 s hook
# timeout, at which point the harness kills the hook and the check silently
# never runs. Headings and list items carry the "is this already on the roadmap"
# signal; the prose between them does not.
DOCS_CONTEXT_MAX_BYTES="${DOCS_CONTEXT_MAX_BYTES:-4000}"

docs_context() {
    local root="${CLAUDE_PROJECT_DIR:-.}" out="" adrs="" features="" roadmap="" total

    adrs=$(git -C "$root" ls-files 'docs/adr/*' 2>/dev/null | grep -v -i 'template' || true)
    features=$(git -C "$root" ls-files 'docs/features/*' 2>/dev/null | grep -v -i 'template' || true)

    if [[ -f "$root/docs/ROADMAP.md" ]]; then
        roadmap=$(LC_ALL=C grep -E '^(#{1,6} |[-*] )' "$root/docs/ROADMAP.md" 2>/dev/null \
            | cut -c1-110 || true)
    fi

    [[ -n "$adrs$features$roadmap" ]] || return 0

    out="Committed ADRs:
${adrs:-none}

Committed feature docs:
${features:-none}

docs/ROADMAP.md — headings and items:
${roadmap:-not found}"

    total=$(printf '%s' "$out" | wc -c | tr -d ' ')
    if (( total > DOCS_CONTEXT_MAX_BYTES )); then
        printf '%s' "$out" | head -c "$DOCS_CONTEXT_MAX_BYTES"
        printf '\n(list truncated — absence from it does NOT prove a document is missing)\n'
    else
        printf '%s\n' "$out"
    fi
    return 0
}

# --- classifier ------------------------------------------------------------

# classify <prompt> — run the judgment call, echo the decision word only
# ("block" or "approve"), plus the reason on the second line. Unparseable
# output yields "approve".
#
# Pinned to a small fast model, and — far more importantly — run from a scratch
# directory with no MCP servers.
#
# The prompt is entirely self-contained, but `claude -p` invoked inside the
# project inherits that project's whole context: CLAUDE.md, every `@`-imported
# memory file, skills, MCP servers. Measured on maker-parts (51 KB memory
# import): 34 s in-project vs 2 s from a neutral cwd, for the identical prompt.
# The hook timeout is 30 s, so the in-project call was reliably killed — which
# went unnoticed only because the old broken role filter usually produced an
# empty window and the hook short-circuited before ever calling out.
CAPTURE_MODEL="${CAPTURE_MODEL:-haiku}"

classify() {
    local response json scratch
    scratch=$(mktemp -d 2>/dev/null) || scratch=""

    if [[ -n "$scratch" ]]; then
        response=$( (cd "$scratch" && printf '%s' "$1" \
            | claude -p --model "$CAPTURE_MODEL" --strict-mcp-config) 2>/dev/null || true)
        rm -rf "$scratch"
    else
        response=$(printf '%s' "$1" | claude -p --model "$CAPTURE_MODEL" 2>/dev/null || true)
    fi
    json=$(printf '%s' "$response" | grep -o '{.*}' | head -1 || true)

    if printf '%s' "$json" | jq -e '.decision' >/dev/null 2>&1; then
        printf '%s\n' "$(printf '%s' "$json" | jq -r '.decision')"
        printf '%s\n' "$(printf '%s' "$json" | jq -r '.reason // ""')"
    else
        printf 'approve\n\n'
    fi
}

# Shared prompt clause. Included by every capture hook so the attribution rule
# and the idempotency exit are worded identically everywhere.
CAPTURE_GROUND_RULES='Ground rules:
- Lines are labelled USER: and ASSISTANT:. Only USER: lines are the user speaking.
  NEVER treat ASSISTANT: text as a user preference, instruction, or correction —
  a suggestion the assistant made and the user did not answer is NOT feedback.
- If the point is already covered by the existing memory index below, return approve.
- When uncertain, return approve. A missed capture costs nothing; a false one
  writes a fabricated fact into long-term memory.'
