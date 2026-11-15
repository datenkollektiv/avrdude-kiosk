# Maintenance Plan

Quarterly maintenance workbook for the AVR Burner kiosk (Flask + avrdude on a Raspberry Pi).
Covers build verification, dependency updates, security scanning, toolchain versions and the CI gap.

## Build & Test

### Build command
`just check` byte-compiles `app.py` and `config.example.py` through `uv run --locked`.
There is no test suite yet (roadmap: "pytest coverage for routes with avrdude mocked").

### What to verify
- [ ] `just install` (`uv sync --locked`) succeeds without re-resolving.
- [ ] `just check` exits 0.
- [ ] Smoke: `just run` in the background, `GET /` on http://localhost:5001 returns 200, then stop the server.
- [ ] Never send POST requests in the smoke test, because they run `sudo avrdude` / `shutdown`.
- [ ] `just lint` (ruff + mypy): record the finding count as a trend; it is informational until the `just qa` roadmap item makes it a gate.

## Dependency Updates

### Python (uv)
- Versions: floors in `pyproject.toml` (runtime `flask>=3.0`, dev group: ruff, mypy, pre-commit); exact pins in `uv.lock`.
- Interpreter: `.python-version` = 3.13, `requires-python = ">=3.13,<3.14"` (Raspberry Pi OS Trixie).
- Strategy: latest within bounds, applied with `just lock` after `uv lock --upgrade` (add a recipe if needed).
- Read the Flask and Werkzeug changelogs before accepting a minor bump.
- Defer major bumps (Flask 4, MarkupSafe/Werkzeug majors) to an explicit decision.
- Keep the `ruff-pre-commit` rev in `.pre-commit-config.yaml` in step with the ruff version in `uv.lock`.

### Toolchain
- uv: `[tool.uv] required-version = ">=0.12,<1"`; check the installed uv and note when 1.0 ships.
- Python 3.13: track the CPython EOL (October 2029) and the Pi OS release that ships it.
- avrdude and just: apt packages on the Pi; record their versions when the kiosk is updated.

### Security scanning
- `just audit`: pip-audit over the locked runtime set (`uv export --no-dev`), which needs network.
- Record each finding with its package, advisory ID, severity and fixed version.

## CI/CD
- There is no CI yet, so nothing exercises `uv.lock` or `just check` on pull requests.
- Each quarter, check whether a minimal workflow (`uv sync --locked` + `just check`) has landed; it is not on the roadmap yet.
- Close stale Dependabot branches that target the deleted `requirements.txt`.

## Deployment
- Kiosk: `git pull`, `uv sync --locked --no-dev`; `start.sh` runs `uv run --locked --no-dev python app.py`.

## Scheduled Maintenance Cadence

### Quarterly
- [ ] Build verification and smoke test (above)
- [ ] `just audit` security scan
- [ ] Bump the pinned pip-audit version in `just audit` to the latest release
- [ ] `just lint` trend
- [ ] Dependency upgrades within bounds; record the before/after closure
- [ ] Toolchain: uv, Python 3.13, avrdude, just
- [ ] CI gap and stale branches
- [ ] Roadmap check: does any maintenance finding belong on `docs/ROADMAP.md`?

## Maintenance Protocol

Each cycle runs on a `maintenance-YYYY-MM-DD` branch and produces files in `audit/`:
1. `YYYY-MM-DD-quarterly-audit.md`: read-only assessment
2. `YYYY-MM-DD-quarterly-plan.md`: executable plan of changes
3. `YYYY-MM-DD-quarterly-maintenance.md`: record of what was applied
