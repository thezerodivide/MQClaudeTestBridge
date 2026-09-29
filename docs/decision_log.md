# MQ Claude Test Bridge Decision Log

Maintained per [Development_Protocol.txt](Development_Protocol.txt) Section 2. This log records *why* material decisions were made and how they evolved. It is distinct from [SPEC.md](../SPEC.md) (*what* the system must do) — do not merge the two, and do not reconstruct this log from memory; append to it as decisions are made.

Each entry is structured into four labeled blocks per §2: **Requirement** (behavior explicitly stated or approved), **Design choices** (the agreed shape of the solution), **Implementation choices** (details free to decide), and **Open** (unresolved questions). Approving a name or a number is not the same as approving a requirement.

## Active overrides index

Entries below that supersede a specification item are indexed here so the supersession is visible without cross-referencing the whole log against the spec. Empty for now — nothing has superseded SPEC.md yet.

---

### DL-001 — Retrofit: seeding this log from SPEC.md's existing "Decisions made" section

- **Status:** Retrofit entry, 2026-09-29. SPEC.md already existed with its own "Decisions made" section before this log did — per Development Protocol §19, work done before the decision log existed still needs an entry, recorded now rather than left undocumented.
- **Requirement:** (1) Claude may only run commands, including chat, that a running test explicitly requires — no general command or chat permission outside a test's declared allowlist; (2) Claude never fixes a bug in a script under test unprompted — it proposes testability hooks and waits for approval before adding anything, and reports findings rather than silently patching.
- **Design choices:** guardrails live in the bridge's Lua code (`claudebridge`), not only in Claude's own instructions, so a bad instruction or a bug in Claude's own reasoning can't bypass them (see SPEC.md "Safety and guardrails").
- **Implementation choices:** none captured yet at this level of generality; see DL-002/DL-003 for the specific mechanisms.
- **Open:** none — this entry only records the general policy; specifics are broken out below.
- **Source:** SPEC.md "Decisions made" and "Safety and guardrails" sections, written 2026-09-29.

---

### DL-002 — v1 scope and non-goals

- **Status:** Confirmed, 2026-09-29 (developer's own initial scoping, recorded here per §19).
- **Requirement:** v1 covers one character, one PC, Lua scripts only, on Project Triune (RoF2 emulator, where automation is explicitly permitted).
- **Design choices:** explicitly out of scope for v1 — C++ plugin builds, multi-character or multi-PC tests, visual/timing judgment ("does it look smooth"), and any use on live Daybreak servers. The roadmap phases (0 through 4) expand scope in a defined order; each phase gate is a specific, checkable condition (e.g. "spellspree suite passes unattended; kill switch tested"), not a vague "when it feels ready."
- **Implementation choices:** phase order (logs-only → one character → boxes on one PC → three PCs on a LAN → public release) — free to reorder if evidence from an early phase justifies it, per Development Protocol §5.
- **Open:** none at this level; each phase's own unknowns are tracked as they're reached (see the ledger's Open implementation details).
- **Source:** SPEC.md "Overview" and "Roadmap" sections.

---

### DL-003 — Guardrail mechanisms: allowlist, kill switch, watchdog, audit log

- **Status:** Confirmed, 2026-09-29 (developer's own design, recorded here per §19).
- **Requirement:** a per-test command allowlist enforced in the bridge (not just documented), including chat commands with their specific target; a kill switch (`/claudestop` in game, or `mq_halt` from Claude's side) that stops the script under test, movement, and combat, then refuses new commands until explicitly restarted; a watchdog that halts the bridge the same way if the MCP server goes quiet for a configured time; every command (allowed or refused) written to an audit log with a timestamp and the running test's name.
- **Design choices:** outside an active test run, only read-only requests are permitted at all — there is no default "general" permission mode. Commands a script under test sends on its own (e.g. autoinv's own reply tells) don't pass through the bridge's allowlist; a test that could trigger them must use fixtures/fake names that keep the side effect harmless, and the test's own proposal must say so explicitly.
- **Implementation choices:** allowlist entries checked after `${...}` expansion, with wildcard support for arguments (e.g. `/nav id *`); watchdog default timeout 5 minutes — an unmeasured first guess (Development Protocol §15), to be revisited only from actual evidence of it firing too early or too late, never adjusted preemptively.
- **Open:** none yet; will need live confirmation that the allowlist/watchdog/kill-switch mechanisms behave as designed once Phase 1's bridge exists — not yet built, so not yet testable.
- **Source:** SPEC.md "Safety and guardrails" section.

---

### DL-004 — Test character convention

- **Status:** Confirmed, 2026-09-29 (developer's own decision, recorded here per §19).
- **Requirement:** test characters are fresh level 1 characters, set up the way the developer normally does — 2nd and 3rd classes obtained, given platinum, moved to Plane of Knowledge. Level 1 characters can scribe spells above their level on Project Triune (a confirmed platform fact, not an implementation choice).
- **Design choices:** a full spellspree buy-and-scribe test consumes a character's unscribed spells and platinum permanently (scribing is not reversible in-game), so a full-buy test needs a fresh character each time it's meant to test the full flow; a rerun against an already-scribed character is itself a valid test (of the "no-op when nothing left to buy" path), not a wasted run.
- **Implementation choices:** none beyond the setup steps stated in the requirement.
- **Open:** how many fresh test characters are needed in practice, and how they'll be reset/regenerated between full-flow test runs, isn't yet decided — revisit once Phase 1's spellspree suite is actually being run repeatedly.
- **Source:** SPEC.md "Decisions made" and the spellspree "Facts that shape the tests" section.

---

### DL-005 — autoinv approval semantics: code is authoritative over prior descriptions

- **Status:** Confirmed, 2026-09-29 (developer's own decision, recorded here per §19).
- **Requirement:** autoinv has exactly one gating switch — guild-only on (sender must be on the guild roster or the extras whitelist) or guild-only off (anyone is allowed). There is no group-only or whitelist-only mode, regardless of what any earlier description of the script claimed.
- **Design choices:** none beyond the above — this is a confirmed-fact correction, not a design decision.
- **Implementation choices:** n/a.
- **Open:** whether a fake-tell injection (`/echo` of "Bob tells you, 'inv'") actually fires `mq.event` on this MacroQuest build is unresolved — this is the deciding factor for whether most of autoinv's Phase-1 tests are runnable with one character or need to wait for Phase 2's second character. See the ledger's Open implementation details and SPEC.md's "Risks and spikes" table.
- **Source:** SPEC.md autoinv section ("What it does," "Facts that shape the tests").
