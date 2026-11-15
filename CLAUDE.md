# CLAUDE.md

@memory/MEMORY.md

## Shared AI Guide

This project uses [AGENTS.md](AGENTS.md) as the cross-tool operating guide for
all AI coding agents. Read it first — it contains the project overview,
architecture, development workflow, and key conventions.

Everything below is Claude Code-specific configuration that layers on top of
AGENTS.md.

## Specialized Agents

The following specialized agents are available and work can be delegated to them.
Prefer delegation when a task touches a domain covered by an agent and involves
multistep work, benefits from the agent's built-in checklist, or can run in
parallel with other work.
For small, focused edits where context is already loaded, direct work is fine.
All project agents (in `.claude/agents/`) are also available globally via the
Task tool with `subagent_type` matching the agent name.

- **python-pro** (project): Delegate writing or changing Python in `app.py` and any new modules.
- **dependency-manager** (project): Delegate adding, removing or upgrading dependencies in `pyproject.toml` and refreshing `uv.lock` (via `just add` / `just lock`, never by hand).
- **test-automator** (project): Delegate writing pytest tests and wiring them into the justfile.
- **code-reviewer** (project): Delegate a correctness review of changed Python, templates or JSON instruction files.
- **justfile-reviewer** (project): Delegate a review of the `justfile` after adding or changing recipes.

## Mandatory Agent Workflow — every non-trivial task

This is a hard requirement. For every task that touches the Flask app, the avrdude integration, code,
or design:

**Step 0 — Clarify, challenge, and align with the roadmap** (before doing anything else):
- Read `docs/ROADMAP.md` and identify which roadmap item this task maps to.
  State it explicitly: "This maps to roadmap item: <item>."
- If no roadmap item matches: ask the user whether to add it to the roadmap
  or whether this is intentionally ad-hoc. Either way, note the decision.
- If the request is ambiguous in scope, approach, or expected outcome — ask.
  One targeted question beats one wrong implementation.
- If a clearly better alternative exists (simpler approach, safer trade-off,
  reuse of something already in the project) — name it and ask whether it
  should be considered before proceeding.
Do not skip this step to appear responsive. A brief clarification exchange
saves far more time than a full rework.

**Step 1 — Analyse** (before writing any code):
Spawn one or more specialist agents using the `Agent` tool (`subagent_type` from
the list in "Specialized Agents" above). At minimum:
- `python-pro` for Flask app and avrdude integration tasks
- `code-reviewer` for any change that affects the avrdude commands or fuse values sent to the MCU

**Step 2 — Plan** (before making changes):
Use `EnterPlanMode` to write out the full plan and get approval. Include: which
files change, which routes/functions are touched, and what the before/after
behaviour looks like.

**Step 3 — Implement with agents**:
Delegate implementation subtasks to specialist agents where the domain matches.
Use the `Agent` tool with `subagent_type` set to the relevant agent name.
Do not do everything in the main context when an agent can handle it better.

**Step 4 — Validate** (before declaring done):
Run `just check`, show the output to the user, and
have the `code-reviewer` agent confirm every assembled `avrdude` command still matches the selected part and target fuses.

**Prefer `just` recipes over ad-hoc commands**
Before running any command inline, check whether a `just` recipe already covers
it. If a sequence of commands will be needed more than once, add a recipe rather
than scripting inline. Keep `just` as the single entry point for all project
operations — extend it rather than work around it.

Agents are listed in the "Specialized Agents" section. Pick the ones that match
the domain. For small single-file edits with no Flask app or avrdude impact, direct
work is acceptable — but Flask app and avrdude tasks always require at minimum a
`python-pro` + `code-reviewer` pair.

## Working Directives

IMPORTANT: These rules apply to every task in this project without exception.

**Validate before declaring done**
After any code or configuration change, run `just check` before marking the task complete.
Never declare done based on code changes alone — always verify the outcome.
If validation fails, diagnose the failure — do not retry the same command. If the
output runs without error but looks wrong, that still counts as failure.
For multi-step tasks, state a brief plan before starting:
  1. [Step] → verify: [check]
  2. [Step] → verify: [check]

**Ask before starting if unclear**
Before starting any task, state your assumptions explicitly — even when the intent
seems clear. If a task has ambiguities — unclear scope, multiple valid approaches,
or missing parameters — ask for clarification before writing any code.
One targeted question beats one wrong implementation.
- "Burn", "write" and "flash" can target fuses, lock bits, flash or EEPROM — ask which memory and which part before touching an `avrdude -U` argument; a wrong fuse value can brick the MCU.

**Temporary files go in `tmp/`**
All intermediate outputs and scratch files go in `tmp/` (project root):
fuse dumps, flash backups, debug output, verification artifacts — any file-based temporary storage needed during a task.
Never use the system `/tmp` or scatter files in the workspace root.
Project-local tmp keeps artifacts discoverable and scoped to the project.
Name temp files to indicate their purpose — `tmp/fuses-m328p-before.txt` not `tmp/test.txt`.

**Use `just` recipes for all run, check and avrdude calls**
Never invoke `python3`, `uv run python` or `avrdude` directly. Use the reusable recipes:
- `just run` — start the web UI on http://localhost:5001
- `just check` — byte-compile the Python sources
- `just fuses <part> <programmer>` — read the fuses of the connected MCU
- `just install` — sync the locked environment (`uv sync --locked`)
- `just lock` — re-resolve `uv.lock` after editing `pyproject.toml`, then sync
- `just add <pkg>` — add a dependency (`uv add`; `--dev` for dev tooling)
If a needed recipe doesn't exist, add it first — that's part of the task.

**Surgical changes only**
Follow the Coding Principles in AGENTS.md.
- The route handlers in `app.py` repeat the same avrdude/subprocess block; do not consolidate them as a side effect of an unrelated change.

## Project Lore

Non-obvious technical discoveries — facts that caused surprising failures or took
significant time to debug — are recorded in `docs/project-lore.md`.

Before closing any debugging or resolution task, ask:
1. Did I spend more than 15 minutes diagnosing a failure?
2. Did the fix require knowledge not obvious from the error message?
3. Would I want to know this at the *start* of the task next time?

If yes: use `/project-lore` to log the finding in `docs/project-lore.md`.
High-value failure patterns that surface repeatedly also belong in a
`## Common Resolution Failures` table (add one if it does not exist yet).

## Common Resolution Failures

| Symptom | Likely cause |
|:--------|:-------------|
| Direct `uv …` call denied with "use just <recipe>" | `just-enforcer.sh` matches recipe first words; use `just add` / `just lock` |
| `just add -- --dev <pkg>` fails inside `uv add` | just forwards `--` literally; use `just add --dev <pkg>` |

## Project Memory

Project context lives in `memory/` and is imported via `@memory/MEMORY.md` above.
It is **gitignored** because this repository is public — it stays in the local checkout and is never published.

**Which tier does a new memory belong in?**
- Working context for this project (decisions, conventions, in-progress state) → `memory/`, with an index line in `memory/MEMORY.md`.
- Anything other contributors need → the committed docs instead: `docs/project-lore.md`, `docs/adr/`, `docs/features/`, or this file.
- Machine-local notes only (local paths, personal workflow quirks) → the per-user `~/.claude` store; keep it thin.

Never copy project facts into the per-user store — that is what makes the two memory stores diverge.

## Documentation Conventions

**Architecture Decision Records** — `docs/adr/NNN-title.md`
Record significant technical decisions (framework choices, data model trade-offs,
integration strategies) as ADRs. Use `docs/adr/000-template.md` as the starting
point. Number sequentially. Reference from `docs/project-lore.md` when an ADR
explains a surprising constraint.

**Feature Documents** — `docs/features/feature-name-vN.md`
Track design decisions, constraints, open questions, and implementation progress
for each feature. Use `docs/features/000-template.md` as the starting point.
Name files descriptively: `notification-service-v1.md`, `auth-migration-v2.md`.
Update the State checklist as work progresses across sessions.
