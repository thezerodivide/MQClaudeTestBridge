# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Authoritative documents

- **[SPEC.md](SPEC.md)** — the specification. What the system must do.
- **[docs/Development_Protocol.txt](docs/Development_Protocol.txt)** — the process contract. How decisions get made and recorded while building it. Carried over unchanged from [PTAutoRoute](https://github.com/thezerodivide/PTAutoRoute), whose v1.0 release retrospective sharpened it based on what actually worked and didn't across that project.
- **[docs/decision_log.md](docs/decision_log.md)** — why material decisions were made and how they evolved. Distinct from the spec.
- **[docs/project_ledger.md](docs/project_ledger.md)** — the project's current state in four categories (Resolved behavior, Confirmed live/system facts, Open implementation details, Out of scope). Read this first when reestablishing context; consult the decision log only as needed.
- **[docs/User_Story_Template.md](docs/User_Story_Template.md)** — how new work starts: the developer supplies a user story; Claude drives the requirements conversation (one question at a time, every item labeled Requirement / Assumption / Open, no solutions before acceptance criteria are approved) and records it in the decision log in four labeled blocks. Decisions, risk judgments and acceptance criteria stay the developer's. Copied from PTAutoRoute and adapted.
- **[docs/lessons_learned.md](docs/lessons_learned.md)** — a running log of lessons, kept for a release retrospective, where the developer triages each entry into Protocol, CLAUDE.md, or noise. Not the protocol itself. Append an entry whenever a lesson appears; leave Triage blank until the retrospective.

The spec and the protocol govern every change made in this repo. Read them in full before a nontrivial behavioral change; the summary below exists so the core rules are loaded every session without re-reading the full protocol each time, not as a replacement for it.

## What this is

MQ Claude Test Bridge lets Claude run MacroQuest Lua script tests end to end with no manual steps: reload a script in-game, drive the test character, read TLOs and logs, decide pass/fail. Two components — `claudebridge` (Lua, in MacroQuest, the only thing that touches the game) and `mq-mcp` (Python MCP server, exposes bridge commands as tools Claude calls). See [SPEC.md](SPEC.md) for the full architecture, command set, test format, and roadmap.

**v1 scope:** one character, one PC, Lua scripts only, Project Triune (RoF2 emulator, automation explicitly permitted). See [SPEC.md](SPEC.md#overview) for non-goals.

Running it (once built, not yet the case): `/lua run claudebridge` in MacroQuest starts the bridge; the MCP server is started by Claude Code from `.mcp.json`.

## Development Protocol — core rules

Full text: [docs/Development_Protocol.txt](docs/Development_Protocol.txt). These are the rules that matter on every change; consult the full document for anything not covered here.

**Source of truth (§1).** The spec is authoritative. Never silently reinterpret or expand an agreed requirement. Keep confirmed fact / agreed requirement / open question / implementation choice distinct at all times.

**Decision log discipline (§2).** Every material decision gets an entry: the decision, why, the evidence, its status, what it supersedes. Structure each entry into four labeled blocks (Requirement / Design choices / Implementation choices / Open). Start from a story — state the observed problem before proposing a mechanism. The decision log is append-only (corrections via a dated addendum); the spec and ledger are current-state documents, updated in place, but never silently — a correction must stay visible as a correction.

**Don't invent requirements (§3).** Normal engineering completeness (cleanup, error handling, diagnostics) is expected without asking; new product behavior is not. Before finalizing a nontrivial design, go through it piece by piece and ask which parts are justified by an actual observation versus reasoning about a problem nobody has seen yet. Anything deferred needs a specific revisit trigger, not a vague "maybe later."

**Resolve unknowns honestly (§4).** Don't guess at MacroQuest/Project Triune/TAC/external behavior — it's an open question until there's evidence. The same standard applies to your own tooling assumptions (shell quoting, stdlib behavior, exit codes) and to facts about the developer's own situation (risk tolerance, constraints) — ask, don't infer. Read a dependency's actual source/documentation and cite the specific location; don't rely on a paraphrase.

**Build from behavior, not the last patch (§5).** Read the existing code before extending it — it can hold a defect the new design would inherit. Reason through the whole affected flow before implementing.

**One change at a time (§6).** Implement → diagnostic review → spec comparison → local tests → inspect evidence as an outside developer → only then hand off for live testing.

**Test requirements, not code paths (§7).** Every test cites its source (a decision log ID, a spec section, a real log line) — never an expected value derived by running the code and pasting the output. Logic-heavy tests need a mutation check: prove the test actually fails when the protected behavior breaks.

**Test-build diagnostics (§8).** Verbose logging by default. Log every command/message sent with its reason, not just the decision. Design diagnostics to distinguish an operator/config mistake from a code defect — a symptom that looks like a bug can be a misconfiguration instead.

**Build identity (§9).** Every test build gets a unique filename and window title; logs identify the build. SemVer, with pre-release identifiers for test builds (`0.1.0-test.4`), not a new release version per iteration.

**Handoff standard (§10).** Never call a build "ready" beyond what the evidence shows. Distinguish local/simulated validation, static review, and live validation explicitly.

**Project ledger (§11).** Read the ledger first at the start of a session; consult the decision log only as needed. Rebuild understanding from the repo and the ledger, not from memory of an earlier conversation — a carried-over summary can be stale or paraphrased in a way that loses a detail that mattered.

**Stop conditions (§12).** Re-baseline against the spec if: implemented behavior differs from what was agreed; it's unclear whether something is a requirement or implementation choice; several consecutive builds are fixes for the previous fix; the implementation has become more complicated than the problem warrants.

**Decision pacing (§17).** Don't ask for a decision while discussion is still open or facts are still being gathered. Don't bundle multiple distinct decisions into one approval. When risk is involved, separate the worst case, the recommendation, and the fact that risk tolerance is the developer's call. If a new fact changes an earlier recommendation, say so explicitly. Name who/what specifically can't do something — "this can't be confirmed" and "this can't be confirmed by the AI, though the developer can see it directly" lead to opposite actions.

**Keep documentation current (§18).** Before any release, and whenever the spec is handed off as authoritative, re-read it end to end and correct any passage still describing a resolved item as open. Don't wait for staleness to be noticed incidentally.

**Cross-repo/session work (§19).** Work done in a different repo, tool, or session still needs a decision log entry before it's "done." If discovered after the fact, retrofit it with the same evidence standard.

**Testability under a constrained runtime (§20).** Default to separating deterministic logic from the MacroQuest-bound layer — but this is a default, not an absolute mandate; don't force a split that distorts the design around genuinely coupled runtime logic.

**Prior art (§21).** See "Related projects" below — check it before designing a new mechanism, and ask if nothing on the list matches.

**Session boundaries (§22).** End a session at a fixed daily cadence, not by judging in the moment whether the current unit of work feels finished. A mid-investigation cut is the mechanism validating ledger sufficiency, not a flaw in it.

## Working agreement: the developer facilitates, Claude surfaces

From 2026-09-29 the design reached a technical depth the developer cannot independently validate in full. The developer facilitates: one decision at a time, risk calls, enforcing the protocol, and using ChatGPT as a second technical reviewer. The developer's lack of objection is not technical validation. For every design item Claude labels each claim as verified (tested or read in source, with where), reasoned but not verified, or unknown; names the assumptions and any conflict with an approved criterion or the spec before asking for a decision; states the worst case and marks what is the developer's risk call; and lists what a second reviewer should check. Pasted reviews are still evaluated on their merits.

## Format of the second reviewer's replies

From 2026-09-29, ChatGPT's replies to design items come in two sections. **"For Claude"** is the technical review: evaluate it on its merits, push back where it is wrong, incomplete or conflicts with verified evidence, the spec, approved criteria or earlier decisions, and use only this section to decide whether an item has reviewer approval or to record technical decisions. **"For Shane"** is a plain-language explanation for the developer: ignore it when updating decision logs, criteria, designs or plans unless the developer says otherwise. The reviewer is not an authority whose recommendations are accepted automatically. An approval closes the current item; a needed material change means approval is withheld, not approved with recommendations appended. A separate issue raised in a review is handled as its own later item. If more context is needed to judge an item, ask for it instead of guessing.

## Safety-sensitive code: the reviewer sees the final code

From 2026-09-29: if the second reviewer's clearance of safety-sensitive code depends on a change the reviewer requested, the reviewer must be shown the resulting code or diff and verify that change independently before the clearance is treated as final. For short safety-sensitive code (for example an FFI call that could crash the client), show the complete file, not a diff, state that it is the exact file that would be installed (with its byte size and SHA-256), and do not install it or give a run command until the reviewer has cleared that exact version and the developer has made the risk decision.

## Approvals on pasted text

The developer sometimes pastes text (for example another reviewer's answer). Pasted text that contains approval language is the developer's approval; they will not paste approval language they do not agree with. The exception: if they ask Claude for its thoughts or for pushback on the pasted text, any approval language in it was included in error and is not approval. If anything they do contradicts this, ask explicitly. Rule stated by the developer, 2026-09-29.

**Refinement from the retrospective (developer's, agreed 2026-09-29).** A paste that is the developer's whole message, with no words of their own, is information only, not approval. The developer labels a paste on its first line: "Approved:" when it carries their approval, "FYI, not approval:" when it does not. A second reviewer's clearance or "clear to begin" text is never the developer's go-ahead to start a step or to commit; that comes only in the developer's own words, and until then Claude states that the step has not started and holds. What prompted it, 2026-09-29: a Step 2 call-out was pasted as the whole message and Claude began reading requirements before the go-ahead (nothing was changed), and a Step 3 call-out arrived the same way and Claude held.

## Commits and pushes

- **Documentation-only commits:** no permission needed (spec, ledger, decision log, lessons log, `CLAUDE.md`, README and similar).
- **Commits that include code** (`.lua`, `.py`, macros, or anything that changes runtime behavior): ask first.
- **Any other commit** (neither docs nor code, such as `.gitignore`, generated data or logs): ask first.
- **Pushes:** governed by the repository durability policy below. This replaces the earlier rule of 2026-09-29 ("every push asks").

**Repository durability policy** (the developer's, approved 2026-09-29, after the second reviewer began working from a separate review copy of this repo (first a git clone, then, by DL-023, a plain folder with no `.git`) and the remote became the durable off-machine copy of committed work). A push to `origin/main` happens only when both gates pass, evaluated over every commit in the range being pushed (`origin/main..HEAD`), not only the newest.

1. **Authorization Gate.** Every commit in the range is authorized to be pushed. A docs-only commit is authorized by the standing permission in this file. A code commit is authorized by the developer's explicit permission for that commit, which includes its push. Any other commit (neither docs nor code, such as `.gitignore`, generated data or logs) is authorized only by the developer's explicit permission. A commit made under an earlier rule without push permission is not authorized until the developer says so.
2. **Safety Gate.** The pre-push scan finds nothing concerning: tracked and staged text checked for the personal Windows folder, email addresses and token-like strings; each new file checked as expected; generated per-machine files confirmed git-ignored. If Claude is unsure about anything, the Safety Gate has not passed.
3. **Neither gate substitutes for the other.** Passing the scan does not grant permission to push, and permission does not override a scan finding or Claude's doubt. If either gate fails, Claude stops before pushing, says which gate failed and why, and asks. Only the developer can clear a finding, explicitly.
4. Push only to `origin/main`; never force push; no new branches or tags without permission; if a push is rejected or fails, stop and report.
5. After every push, report the range pushed and the result of both gates.

The repository is public: every push is world-readable and cannot be undone cleanly.

## Related projects (Development Protocol §21)

Other projects by this developer, same MacroQuest/Project Triune platform, checked for prior art before designing a new mechanism here.

- **PTAutoRoute (PTAR)** (`https://github.com/thezerodivide/PTAutoRoute`) — dungeon route automation. Source of the atomic-save pattern (`.tmp` write → verify → promote → `.bak`), the MacroQuest-free pure-logic-module pattern for testability, and the append-only decision-log/retrofit convention this project's own docs follow. This *is* the Development Protocol's origin project — read its decision log if a design question here resembles one PTAR already worked through (multi-character coordination, TAC integration via `/ac status`, combat-interrupt handling).
- **PTDeathRecovery** (`lua/PTDR.lua` in PTAR's reference material) — death detection/recovery. Source of the verified `/ac status` query-guard pattern (query-active guard, treat acknowledgement as not proof, bounded retries).
- **PTItemEvolver** (`https://github.com/thezerodivide/PTItemEvolver`) — item evolution queue management.

## Architecture

Partly built. Step 1 exists: `lua/claudebridge/version.lua` and `python/mq_mcp/version.py` (the version and identity checks), with their tests and the test harness. The rest (queue, core, store, loop, the MCP server, build packaging) is not built; see [SPEC.md](SPEC.md#architecture) for the designed shape (`claudebridge` Lua bridge, `mq-mcp` Python MCP server, file-based transport) and DL-022 for the build order. This section will describe the actual module layout as it grows; don't let it drift from the code the way [PTAutoRoute](https://github.com/thezerodivide/PTAutoRoute)'s spec did before its v1.0 release pass caught it (Development Protocol §18).

## Testing

`test\check.cmd` runs the syntax check, then the Lua tests (`test/harness/run.lua`, each `test/*_test.lua` in its own subprocess), then the Python tests (`python -m unittest discover` on `python/tests`), and exits 0 only if all three pass. The harness is adapted from PTAutoRoute, Lester is vendored unmodified in `test/vendor/`, and each test names the requirement it comes from. Apply §20: separate anything worth unit-testing from the MacroQuest-bound adapter code, the same way PTAR's `PTARRunnerCore.lua` has zero MQ dependency. The TOML test format in SPEC.md is a separate, live-game test layer on top of that — not a replacement for it.
