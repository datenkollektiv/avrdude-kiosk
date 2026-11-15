# AGENTS.md

> Use this file as the fast-path operating guide for AI coding agents.
> Prefer repository truth over assumptions — check the files referenced below.

## Project Overview

AVR Burner is a single-file Flask app that reads fuses and flashes ATmega MCUs (m328p, m168pa, m88pa) through `avrdude` and a USBasp programmer.
It runs as a kiosk on a Raspberry Pi with the programmer attached.

## Architecture

- `app.py` holds every route; each POST route assembles an `avrdude` command string and runs it with `subprocess.Popen(command.split())`.
- `templates/index.html` is the only page; its forms post to `/read-fuses`, `/burn-low-fuse`, `/read-flash`, `/flash`, `/download` and `/shutdown`.
- UI state lives in the module-global `page_data` dict, shared across all requests.
- `/download` loads target part, fuses and hex file name from `instructions.json`; the `instructions-*-example.json` files are variants per part/programmer.
- Runtime settings come from an optional, gitignored `config.py` (copy `config.example.py`); without it `app.py` falls back to `sudo avrdude` and `sudo shutdown -h now`.

## Development Workflow

- `just run` — start the UI on http://localhost:5001.
- `just check` — byte-compile the Python sources; there are no tests yet.
- `just fuses m328p usbasp` — read fuses of the connected MCU.
- `just install` — runs `uv sync --locked` to sync `.venv` from `pyproject.toml` + `uv.lock`; `.python-version` pins 3.13.
- `just lock` — `uv lock` + `uv sync --locked` after editing `pyproject.toml`.
- `just add <pkg>` — `uv add <pkg>`; updates `pyproject.toml` and `uv.lock`.
- `just audit` / `just lint` — pip-audit of the runtime deps; ruff + mypy report (informational). See `maintenance-plan.md`.

## Key Conventions

- MCU display names map to avrdude part ids in `map_mcu_full_name_to_AVR_part`; add new parts there.
- `.hex`/`.eep` files and `config.py` are gitignored — never commit firmware images or local config.
- Cheap USBasp clones need `-B 125kHz`, which `app.py` does not pass yet (see README Known Issues).

## Coding Principles

- **State assumptions** before starting. If a task has multiple valid interpretations, present them rather than picking silently.
- **Simplicity first.** Minimum code that solves the problem. No features beyond what was asked. No abstractions for single-use code. No error handling for impossible scenarios.
- **Surgical changes.** Touch only what the task requires. Do not improve adjacent code, comments, or formatting. Every changed line should trace directly to the user's request.
- When your changes create orphans (unused imports, variables, functions), remove them. Do not remove pre-existing dead code unless asked.
- **Recorded knowledge is load-bearing — verify before acting on it.** README notes, comments, and any project lore/knowledge file capture point-in-time facts that quietly drift; they are read once and trusted for months. Treat a recorded claim — especially one that steers automated behaviour (build, CI, permissions, scripts) — as a hypothesis to confirm against the current code, not as ground truth. The dangerous claim is the one that still *reads* authoritative while the reason underneath it has rotted.

## Important Files

- `app.py` — all server logic and every `avrdude` invocation.
- `config.example.py` — the configurable settings and their meaning.
- `README.md` — hardware prerequisites, manual fuse commands, Known Issues.
- `docs/ROADMAP.md` — current priorities.
- `docs/project-lore.md` — non-obvious findings; entries are point-in-time, verify against current code before acting on them.
