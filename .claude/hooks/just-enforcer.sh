#!/usr/bin/env bash
set -euo pipefail
# just-enforcer.sh — PreToolUse hook: block direct invocations of commands
# that have a `just` recipe wrapper. Forces reproducible, recipe-based workflows.
#
# Claude Code passes hook input as JSON on stdin:
#   { "tool_name": "Bash", "tool_input": { "command": "..." } }
#
# Outputs the canonical PreToolUse hook format (matching the block-* hooks):
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                          "permissionDecision":"deny",
#                          "permissionDecisionReason":"..."}}
# On no match, exits 0 with no output so other hooks and permissions still apply.

HOOK_INPUT=$(cat)

# Only intercept Bash calls.
TOOL_NAME=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // ""')
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

COMMAND=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // ""')
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Find the justfile.
JUSTFILE=""
for candidate in justfile Justfile JUSTFILE; do
    if [[ -f "$candidate" ]]; then
        JUSTFILE="$candidate"
        break
    fi
done

if [[ -z "$JUSTFILE" ]]; then
    exit 0
fi

# Always-allowed commands that should never be blocked, even if they appear
# inside a recipe body. These are read-only inspection commands, shell basics,
# and git operations that agents need for routine work.
ALLOW_PATTERNS=(
    "^cat "
    "^head "
    "^tail "
    "^ls"
    "^find "
    "^tree"
    "^wc "
    "^echo "
    "^printf "
    "^grep "
    "^rg "
    "^diff "
    "^git "
    "^just "
    "^cd "
    "^pwd"
    "^mkdir "
    "^chmod "
    # File basics: a recipe that copies or links files as one step must not
    # turn every direct cp/mv/rm in the session into "use just <recipe>".
    "^cp "
    "^mv "
    "^rm "
    "^ln "
    "^touch "
    "^which "
    "^command "
    "^type "
    "^test "
    "^\["
    "^true$"
    "^false$"
    "^env "
    "^export "
    "^source "
    # `. file` (source) only — a bare "^\." also admitted every ./gradlew, ./mvnw.
    "^\. "
)

for pattern in "${ALLOW_PATTERNS[@]}"; do
    if [[ "$COMMAND" =~ $pattern ]]; then
        exit 0
    fi
done

# Build a map of command prefixes → recipe names from the justfile.
# For each recipe, extract the first non-comment, non-empty command line
# and strip leading whitespace. This gives us the "raw command" the recipe wraps.
#
# Format: RECIPE_NAME<tab>COMMAND_PREFIX
RECIPE_MAP=$(awk '
    # Recipe header: name ( [+]?[name] [= default] | *name )* :
    # The previous regex required the first parameter to begin with + or a
    # letter/underscore, so `flash *name:` (a positional-arg recipe) was
    # silently skipped. The leading `[a-zA-Z_]` is mandatory and is the
    # recipe name; everything between it and the trailing `:` is parameter
    # syntax we do not need to validate here.
    /^[a-zA-Z_][a-zA-Z0-9_-]*[ \t]*[^\t :#].*:/ {
        name = $0
        sub(/[ \t:].*/, "", name)
        in_recipe = 1
        recipe_name = name
        next
    }
    in_recipe && /^[^ \t#]/ { in_recipe = 0 }
    in_recipe && /^[ \t]/ {
        line = $0
        sub(/^[ \t]+/, "", line)
        # Test the first non-whitespace character explicitly. The previous
        # guard tried to combine anchoring and a [#@] test in one character
        # class (`^[ \t]+[^#@]`), which POSIX ERE does not require to consume
        # all leading whitespace — so a `    #!/usr/bin/env sh` line slipped
        # through and registered its "command" as the literal `#!/usr/bin/env`.
        if (line ~ /^#/) next
        sub(/^@[-+]?|^-@/, "", line)   # strip just silent / error-suppress prefixes
        sub(/^[ \t]+/, "", line)
        if (line == "") next
        # Shebang-line preamble: skip shell setup lines until we hit a real
        # command. `set`, `IFS=`, and `export` are configuration, not the
        # command the recipe wraps.
        if (line ~ /^(set |set$|IFS=|export )/) next
        # Skip lines that are just variable assignments or conditionals
        if (line ~ /^(if |for |while |do |done|fi |else|elif )/) next
        if (line ~ /^[A-Z_]+=[^ ]/) next
        # Get the command name (first word). Emit one row per real command
        # line, not just the first — a recipe body may legitimately have an
        # `@echo "starting …"` preamble before the wrapped command, and the
        # hook needs to see the wrapped command, not the preamble.
        cmd = line
        sub(/ .*/, "", cmd)
        prefix = line
        sub(/{{[^}]*}}/, "PARAM", prefix)  # normalise just variables
        print recipe_name "\t" cmd "\t" prefix
        next
    }
' "$JUSTFILE")

if [[ -z "$RECIPE_MAP" ]]; then
    exit 0
fi

# Extract the first word of the command being run.
CMD_FIRST_WORD="${COMMAND%% *}"

# Check if any recipe wraps a command starting with the same binary.
MATCHING_RECIPE=""
while IFS=$'\t' read -r recipe cmd prefix; do
    if [[ "$CMD_FIRST_WORD" == "$cmd" ]]; then
        # Found a recipe whose underlying command matches.
        MATCHING_RECIPE="$recipe"
        break
    fi
done <<< "$RECIPE_MAP"

if [[ -n "$MATCHING_RECIPE" ]]; then
    REASON="Use \`just $MATCHING_RECIPE\` instead of running \`$CMD_FIRST_WORD\` directly. The project uses just recipes for reproducible, documented workflows. If no existing recipe fits, add one to the justfile first — that is part of the task."
    jq -nc --arg reason "$REASON" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $reason
        }
    }'
fi

exit 0
