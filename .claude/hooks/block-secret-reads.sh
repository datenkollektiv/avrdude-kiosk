#!/usr/bin/env bash
set -euo pipefail
# block-secret-reads.sh — PreToolUse hook: hard-deny any Bash command that
# would read OR write a project secret file (`.env`, private keys, certs, …).
#
# Why a hook and not just a Read-tool deny rule? The project allow-list grants
# broad `cat`/`grep`/`head`/`tail`/`cp` access, so a declarative
# `permissions.deny: ["Read(.env)"]` only stops the *Read tool* — a plain
# `cat .env` would still leak the file. This hook inspects the raw Bash command
# string and closes that gap. The two layers share one source of truth:
# `.claude/deny-files.txt` (the /onboard skill expands the same file into the
# Read deny rules).
#
# Config — `.claude/deny-files.txt`, one gitignore-style glob per line:
#   .env            a file literally named .env
#   .env.*          .env.local, .env.production, …
#   *.pem           any .pem file
#   secrets/**      anything under secrets/
#   # lines starting with # and blank lines are ignored
# If the file is absent, the built-in DEFAULTS below are used.
#
# Matching notes:
#   * `*`  -> one path segment (no `/`, no whitespace)
#   * `**` -> anything (crosses `/`)
#   * each pattern is anchored on a path boundary, so `.env` matches `.env`,
#     `./.env`, `> .env` but NOT `.envrc` or the word `environment`.
#
# Outputs the canonical PreToolUse deny format on a match; exits 0 with no
# output otherwise so other hooks and permissions still apply. Runs on every
# Bash call regardless of allow-list, so it cannot be edited around mid-session.

DEFAULTS=(".env" ".env.*" "*.pem" "*.key" "secrets/**")

HOOK_INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // ""')
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

COMMAND=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // ""')
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Load deny patterns from .claude/deny-files.txt, or fall back to DEFAULTS.
DENY_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/deny-files.txt"
patterns=()
if [[ -f "$DENY_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                          # strip inline/full comments
        line="${line#"${line%%[![:space:]]*}"}"     # ltrim
        line="${line%"${line##*[![:space:]]}"}"     # rtrim
        [[ -z "$line" ]] && continue
        patterns+=("$line")
    done < "$DENY_FILE"
else
    patterns=("${DEFAULTS[@]}")
fi

[[ ${#patterns[@]} -eq 0 ]] && exit 0

# Translate one gitignore-style glob into an anchored ERE fragment.
glob_to_regex() {
    local g="$1"
    g="${g#./}"                 # a leading ./ is implicit
    g="${g//./\\.}"             # escape literal dots
    g="${g//\*\*/$'\x01'}"      # ** -> placeholder
    g="${g//\*/[^/[:space:]]*}" # *  -> one path segment
    g="${g//$'\x01'/.*}"        # placeholder -> anything
    # Left boundary: start or a char that cannot be part of a filename token.
    # Right boundary: end or a non-alphanumeric (keeps `.env` from matching `.envrc`).
    printf '(^|[^[:alnum:]._-])%s($|[^[:alnum:]])' "$g"
}

for pattern in "${patterns[@]}"; do
    regex=$(glob_to_regex "$pattern")
    if [[ "$COMMAND" =~ $regex ]]; then
        REASON="Blocked by block-secret-reads hook: \`$COMMAND\` touches a protected secret file (matched \`$pattern\` in .claude/deny-files.txt). Reading or writing secrets is forbidden — ask the user to read/edit the file themselves."
        jq -nc --arg reason "$REASON" '{
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: $reason
            }
        }'
        exit 0
    fi
done

exit 0
