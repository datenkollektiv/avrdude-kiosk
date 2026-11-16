---
gate: none
desk-work: available
---

# Feature: asynchronous avrdude with progress v1

Roadmap: Mid term, "Run avrdude asynchronously with progress feedback".
Source: README Known Issue "(copilot) The `avrdude` command is executed synchronously".

## Decisions
| Decision | Reason | Rejected Alternative |
|----------|--------|----------------------|
| Run avrdude off the request thread and report progress | A flash blocks the page with no feedback | Keep blocking `communicate()` |

## Constraints
- The avrdude POST routes (`/read-fuses`, `/burn-low-fuse`, `/read-flash`, `/flash`) block on `subprocess.Popen(...).communicate()` until avrdude exits.
- One programmer is attached, so at most one avrdude job may run at a time.
- UI state lives in the module-global `page_data`, shared across all requests.
- The kiosk is a Raspberry Pi, so a broker stack (Celery, Redis) is too heavy.
- The assembled avrdude commands and fuse values must stay byte-identical.

## Open Questions
- [ ] Progress transport: server-sent events, polling, or WebSockets?
- [ ] Worker model: a single background thread with a lock, or a subprocess queue?
- [ ] Can avrdude's `#` progress bar on stderr be parsed reliably, or report phases only?
- [ ] Should a running job be cancellable, and what does that leave on the MCU?
- [ ] Does this consolidate the repeated avrdude block in `app.py` (CLAUDE.md forbids doing so incidentally)?
- [ ] Land after "pytest coverage for routes with avrdude mocked" so the refactor has tests?

## State
- [ ] Design approved
- [ ] Core implementation
- [ ] Tests passing
- [ ] Documentation updated

## Session Log
- 2026-11-15 — Feature doc drafted from the README Known Issues via /feature
