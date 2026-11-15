#!/usr/bin/env bash

set -x

MY_PATH="$(dirname -- "${BASH_SOURCE[0]}")"            # relative

cd -- "$MY_PATH"
# Autostart often has a minimal PATH; the uv installer puts uv in ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null || { echo "uv not found on PATH" >&2; exit 1; }
# --no-dev: the kiosk needs only the runtime deps, not ruff/mypy/pre-commit
uv run --locked --no-dev python app.py&

