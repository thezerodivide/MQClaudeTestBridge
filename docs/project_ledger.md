# MQ Claude Test Bridge Project Ledger

Maintained per [Development_Protocol.txt](Development_Protocol.txt) Section 11. This ledger tracks the project's *current state* in four categories. Read this first to orient; consult [decision_log.md](decision_log.md) for the rationale, history, and active overrides behind any entry only as needed — don't reconstruct current state by reading the full decision log from scratch.

When new evidence resolves an open question, update this ledger before building on that conclusion. Do not silently rewrite prior entries — if something here turns out wrong, record the correction and, if the correction is material, add a decision log entry explaining why.

## Up next

**Phase 0 (logs access) has not started yet.** Nothing is built. Per SPEC.md's roadmap, Phase 0 needs no code — Claude reads MacroQuest and EverQuest log files directly — and can start immediately. The four Phase 1 spikes (see Open implementation details below) are the next real unknowns to resolve, before `claudebridge` or `mq-mcp` are built.

## Dependencies (not yet built)

Everything. This is a pre-Phase-0 project. Listed here for visibility, not because any are blocked on each other in a complex way:

- `claudebridge` (Lua, in MacroQuest) — the only thing that touches the game.
- `mq-mcp` (Python MCP server) — turns bridge commands into Claude-callable tools.
- The TOML test format and runner.
- The four Phase 1 spikes (below) need answers before the bridge's transport/error-capture design is locked in.

## Pending Live Verification

Nothing built yet, so nothing to verify. This section will track implemented-but-unconfirmed behavior once Phase 1 starts, the same way [PTAutoRoute](https://github.com/thezerodivide/PTAutoRoute)'s ledger did.

## Resolved behavior

Behavior actually agreed upon (source: [SPEC.md](../SPEC.md), approved as current source of truth).

- Two-part architecture: `claudebridge` (Lua, in MacroQuest, the only thing that touches the game) and `mq-mcp` (Python MCP server, turns bridge commands into Claude-callable tools). Claude never touches the game directly — every action goes through the MCP server and the shared folder to the bridge.
- Transport is files (an inbox/outbox folder, polled ~100ms), not sockets, for v1 — sockets are deferred to Phase 3 (multi-PC).
- A per-test command allowlist enforced in the bridge itself, not just in Claude's instructions — see [DL-003](decision_log.md#dl-003--guardrail-mechanisms-allowlist-kill-switch-watchdog-audit-log).
- Claude designs its own unhappy-path tests from reading the script under test, rather than only confirming the happy path; a standard checklist (window closed mid-run, malformed input, timeouts, repeated/spammed input, mid-run stop/restart/zone, resource exhaustion) applies to every script tested.
- Claude never fixes a bug in a script under test unprompted — it proposes testability hooks, gets approval before adding anything, and reports findings for the developer to act on. See [DL-001](decision_log.md#dl-001--retrofit-seeding-this-log-from-specmd-existing-decisions-made-section).
- Test character convention: fresh level 1, 2nd/3rd classes obtained, given platinum, moved to PoK. See [DL-004](decision_log.md#dl-004--test-character-convention).
- autoinv has exactly one gating switch (guild-only on/off); no group-only or whitelist-only mode. See [DL-005](decision_log.md#dl-005--autoinv-approval-semantics-code-is-authoritative-over-prior-descriptions).

## Confirmed live/system facts

Facts established through testing, source inspection, logs, or documentation.

- Level 1 characters can scribe spells above their level on Project Triune.
- Tell-to-self prints "Talking to yourself again?" rather than a normal tell line — can't be used to drive autoinv's tell-triggered behavior.
- autoinv already logs structured lines (`INVITE`, `DENY`, `DZADD`, `DZREMOVE`, roster parse, `STATUS`) to `config\AutoInvite\autoinvite.log`, reset on each load — ready-made assertion targets, no testability hook needed for these.
- autoinv already has a full command interface (`/autoinv` covers every setting plus `refresh`, `roster`, `status`) — no testability gap there.
- spellspree has no command interface at all; vendor selection and Start exist only as ImGui checkboxes/buttons — a real testability gap, addressed by the proposed hooks in SPEC.md's spellspree section.
- spellspree's scribing is permanent in-game; a rerun after a tier is scribed buys nothing (the usable-only filter hides already-scribed spells).

## Open implementation details

Questions intentionally unresolved — do not decide these unilaterally; surface them for discussion when they become relevant. These are SPEC.md's "Risks and spikes," carried here so they're tracked as ledger items, not just prose in the spec.

- **Does a catch-all `mq.event` see `print()` output from other Lua scripts, or only EverQuest chat?** Decides how script output reaches Claude. Fallback: the runner and `testlog` write to `events.jsonl` directly.
- **Exact values of `${Lua.Script[name].Status}` (running/exited/error) on this build.** Test steps wait on them. Fallback: poll `/lua ps` output instead.
- **Can the runner wrap a script's main loop in `pcall` without changing its behavior?** Needed for tracebacks. Fallback: read errors from the MQ console log.
- **Does the `mcp` Python SDK install cleanly on Python 3.14?** The MCP server depends on it. Fallback: a separate Python 3.12/3.13 install for the server.
- **Can `/echo` of a fake tell fire `mq.event`?** Decides whether most of autoinv's tests run with one character in Phase 1, or wait for Phase 2's second character. Fallback: move tell tests to Phase 2.
- **How many fresh test characters are needed, and how are they reset between full-flow spellspree runs?** See [DL-004](decision_log.md#dl-004--test-character-convention).
- Every "assumed" path in SPEC.md's Environment table (Lua scripts dir, MacroQuest logs dir, EQ logs dir) — MacroQuest defaults, to be confirmed during setup rather than trusted as-is.

## Out of scope

Explicitly decided not to build or investigate for v1 (SPEC.md "Non-goals for v1").

- C++ plugin builds.
- Multi-character or multi-PC tests (deferred to Phases 2/3, not out of scope forever — just not v1).
- Visual or timing judgment ("does it look smooth").
- Any use on live Daybreak servers — Project Triune (RoF2 emulator) only, where automation is explicitly permitted.
