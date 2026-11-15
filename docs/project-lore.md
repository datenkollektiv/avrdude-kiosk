# Project Lore

This file records non-obvious technical discoveries: facts that caused surprising
failures, took significant time to debug, or would save a future developer 30+
minutes if known upfront.

Refer to `CLAUDE.md` and the `/project-lore` skill for recording guidelines.

---

## Agent Hooks

**`.claude/hooks/just-enforcer.sh` denies any direct command whose first word starts a line in a justfile recipe.**
Since the uv migration, `install`, `lock` and `add` start with `uv`, so every direct `uv …` call is rejected with "use just <recipe>".
The reverse also holds: `run` and `check` start with `{{python}}`, so a direct `python3` is no longer caught by the hook.
The "never invoke `python3`" rule in `CLAUDE.md` is therefore enforced by text only.
Fix: route uv work through `just add` / `just lock`, and add a recipe before using a new uv subcommand.

---

## justfile

**`just add --dev <pkg>` works; `just add -- --dev <pkg>` breaks.**
just stops parsing its own flags after the recipe name, but forwards a `--` separator literally, so uv would read `--dev` as a package name.
The `add` recipe uses `[positional-arguments]` with `uv add "$@"`, because an unquoted `uv add {{args}}` turns `foo>=1,<2` into shell redirects.
Verified with just 1.59.0.
