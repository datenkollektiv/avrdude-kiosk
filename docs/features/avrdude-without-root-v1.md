---
gate: hardware
gate-note: Verify the udev rule on the kiosk Pi with the USBasp attached
desk-work: available
---

# Feature: avrdude without root v1

Roadmap: Long term, "Drop root for avrdude via udev rules for the USBasp".
Source: README Known Issue "(copilot) The `avrdude` command is executed as `root` (via `sudo`)".

## Decisions
| Decision | Reason | Rejected Alternative |
|----------|--------|----------------------|
| Grant USBasp access via a udev rule | avrdude needs device access, not root | Keep `sudo avrdude` |

## Constraints
- Without `config.py`, `app.py` falls back to `sudo avrdude` and `sudo shutdown -h now`.
- `config.example.py` already uses plain `avrdude`, so configured kiosks may differ from the fallback.
- The app runs as a kiosk user started by `start.sh`.
- Changing an existing kiosk must not leave it unable to reach the programmer.

## Open Questions
- [ ] Which USB ID does the kiosk's programmer report (`lsusb`)? `16c0:05dc` is common for USBasp, but clones vary.
- [ ] Ship the rule in the repo (e.g. `udev/99-usbasp.rules`) or document it in the README only?
- [ ] Which group gets access on Pi OS Trixie (`plugdev`, a dedicated group, or `uaccess`)?
- [ ] Should the no-config fallback switch from `sudo avrdude` to `avrdude`?
- [ ] Is de-rooting `SHUTDOWN_COMMAND` (e.g. polkit/`systemctl poweroff`) in scope or a separate feature?

## State
- [ ] Design approved
- [ ] Core implementation
- [ ] Tests passing
- [ ] Documentation updated

## Session Log
- 2026-11-15 — Feature doc drafted from the README Known Issues via /feature
