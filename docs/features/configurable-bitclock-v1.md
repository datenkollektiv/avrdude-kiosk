---
gate: hardware
gate-note: Test with a cheap USBasp clone against a factory-fused (1 MHz) ATmega328P
desk-work: available
---

# Feature: configurable avrdude bit clock v1

Roadmap: Near term, "Configurable avrdude bit clock (-B 125kHz for cheap USBasp)".
Source: README Known Issue "fixed set of parameters ... `-B 125kHz` required, for cheap USBasp devices".

## Decisions
| Decision | Reason | Rejected Alternative |
|----------|--------|----------------------|
| Make the `-B` bit clock configurable | Cheap clones need it; good programmers don't | Hard-code `-B 125kHz` everywhere |

## Constraints
- `app.py` assembles four avrdude commands (read fuses, burn low fuse, read flash, flash) and none passes `-B`.
- `just fuses` also calls avrdude without `-B`.
- Factory `lfuse 0x62` (CKDIV8, 1 MHz) needs an ISP clock below 1/4 of the CPU clock, so 125kHz works.
- After burning `lfuse 0xe2` (8 MHz, `instructions-m328p-example-fast.json`) a faster ISP clock is possible.
- Every changed command must be reviewed by `code-reviewer` against part and fuses (CLAUDE.md).

## Open Questions
- [ ] Config key name and format (e.g. `AVR_BITCLOCK = "125kHz"` in `config.py`)?
- [ ] Global setting only, or also per job in `instructions.json`?
- [ ] Should `just fuses` gain a `bitclock` parameter?
- [ ] When unset (or without `config.py`), omit `-B` as today, or default to 125kHz?

## State
- [ ] Design approved
- [ ] Core implementation
- [ ] Tests passing
- [ ] Documentation updated

## Session Log
- 2026-11-15 — Feature doc drafted from the README Known Issues via /feature
