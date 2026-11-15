python := "uv run --locked python"

# List available recipes
default:
    @just --list

# Sync the locked environment into .venv with uv (run and check also sync .venv, but fail if uv.lock is stale)
install:
    uv sync --locked

# Run the AVR Burner web UI on http://localhost:5001
run:
    {{python}} app.py

# Byte-compile the Python sources to catch syntax errors
check:
    {{python}} -m py_compile app.py config.example.py

# Re-resolve uv.lock after editing pyproject.toml, then sync
lock:
    uv lock
    uv sync --locked

# Add a runtime dependency (use `just add --dev <pkg>` for dev tooling); updates pyproject.toml and uv.lock
[positional-arguments]
add +args:
    uv add "$@"

# Read the fuses of the connected MCU to stdout
fuses part="m328p" programmer="usbasp":
    avrdude -c {{programmer}} -p {{part}} -U lfuse:r:-:h -U hfuse:r:-:h -U efuse:r:-:h

import? '.devcontainer/yolo.just'
