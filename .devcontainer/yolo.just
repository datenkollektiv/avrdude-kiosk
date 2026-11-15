# Agent sandbox recipes — imported by the project justfile via `import? '.devcontainer/yolo.just'` (just >= 1.33).
# Bypass mode is opt-in and only sane behind the firewall: every yolo recipe depends on _require-container.

# Refuse outside the devcontainer, without the root-written firewall marker, or when example.com is reachable
_require-container:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${DEVCONTAINER:-}" != "true" ]; then
        echo "Refusing: not inside the agent sandbox (DEVCONTAINER unset)." >&2
        exit 1
    fi
    if [ ! -f /run/agent-sandbox/firewall-ok ]; then
        echo "Refusing: firewall not verified; run: sudo /usr/local/bin/init-firewall.sh" >&2
        exit 1
    fi
    if curl --connect-timeout 5 -s -o /dev/null https://example.com; then
        echo "Refusing: example.com is reachable, the firewall is down; run: sudo /usr/local/bin/init-firewall.sh" >&2
        exit 1
    fi

# Claude Code with permission prompts skipped (PreToolUse hooks and deny rules still apply)
[confirm("Bypass mode: Claude runs every edit and command unprompted behind the firewall. Continue?")]
[group('devcontainer')]
yolo-claude *args: _require-container
    claude --dangerously-skip-permissions {{ args }}

# Codex with approvals and its own sandbox off
[confirm("Codex bypass: no approvals, no inner sandbox. Continue?")]
[group('devcontainer')]
yolo-codex *args: _require-container
    codex --dangerously-bypass-approvals-and-sandbox {{ args }}

# Gemini CLI auto-approving every tool call
[confirm("Gemini yolo: auto-approves every action. Continue?")]
[group('devcontainer')]
yolo-gemini *args: _require-container
    gemini --approval-mode=yolo {{ args }}

# OpenCode TUI with every permission allowed for this process only
[confirm("OpenCode auto-approve: everything not denied by /etc/opencode/opencode.json runs. Continue?")]
[group('devcontainer')]
yolo-opencode *args: _require-container
    OPENCODE_CONFIG_CONTENT='{"permissions":[{"action":"*","resource":"*","effect":"allow"}]}' opencode {{ args }}

# Prove the firewall is up: example.com must be unreachable, the Claude API reachable
[group('devcontainer')]
firewall-check:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ "${DEVCONTAINER:-}" != "true" ]; then
        echo "Not inside the agent sandbox; use 'just allowlist-check' on the host."
        exit 1
    fi
    if curl --connect-timeout 5 -s -o /dev/null https://example.com; then
        echo "FAIL: example.com reachable — firewall is down; run: sudo /usr/local/bin/init-firewall.sh"
        exit 1
    fi
    echo "OK: example.com blocked"
    if curl --connect-timeout 5 -s -o /dev/null https://api.anthropic.com/; then
        echo "OK: api.anthropic.com reachable"
    else
        echo "FAIL: api.anthropic.com unreachable"
        exit 1
    fi

# Print the domains the fragments will allow, without root or iptables (works on the host too)
[group('devcontainer')]
allowlist-check:
    bash .devcontainer/init-firewall.sh --check .devcontainer/allowlist.d
