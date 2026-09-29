# MQ Claude Test Bridge Decision Log

Maintained per [Development_Protocol.txt](Development_Protocol.txt) Section 2. This log records *why* material decisions were made and how they evolved. It is distinct from [SPEC.md](../SPEC.md) (*what* the system must do) — do not merge the two, and do not reconstruct this log from memory; append to it as decisions are made.

Each entry is structured into four labeled blocks per §2: **Requirement** (behavior explicitly stated or approved), **Design choices** (the agreed shape of the solution), **Implementation choices** (details free to decide), and **Open** (unresolved questions). Approving a name or a number is not the same as approving a requirement.

## Active overrides index

Entries below that supersede a specification item are indexed here so the supersession is visible without cross-referencing the whole log against the spec. - **DL-014** SUPERSEDES SPEC.md's error-capturing `claudebridge/runner` (Architecture diagram, `lua_run`, `lua_reload`, `lua_status`, "Error capture", Phase 1 roadmap box): crashes are detected from the error chat text instead; the runner is out of v1.

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

---

### DL-006 — Phase 0 log path verification

- **Status:** Confirmed, 2026-09-29. The spec's Environment table marked three paths "assumed" and the ledger tracked them as an open item, so Phase 0 began by checking them on disk. Nothing built; no code involved.
- **Requirement:** Claude must be able to read the MacroQuest and EverQuest log files directly from this machine before Phase 1 begins (SPEC.md Roadmap, Phase 0). The Phase 0 result: the Lua scripts folder, the MacroQuest logs folder and the EverQuest logs folder all exist at the assumed locations and are readable, including the live EverQuest log while the game is running.
- **Design choices:** the spec's Environment table now marks those three paths "confirmed" and records the real folder name `Logs` (capital L). Because scripts log to different places (PTAR and PTDeathRecovery under `Logs\`, autoinv to `config\AutoInvite\autoinvite.log`), the spec notes that `log_tail` and `log_search` need a configurable list of log locations, not a single folder. Because some logs are very large, they read from the end of a file or stream it.
- **Implementation choices:** none.
- **Open:** (1) No file in the MacroQuest `Logs` folder was found that records console or Lua `print()` output. Whether MacroQuest can be made to write it, and why it isn't now, is not established; it bears on the first Phase 1 spike. (2) Python 3.14.7 and the autoinv log path were not checked. (3) Whether Phase 0 satisfies its gate ("setup confirmed") is the developer's decision and has not been made.
- **Source:** on-disk checks of the three folders, a live read of `eqlog_Kylaeris_multiclass.txt`, and a listing of the MacroQuest `Logs` folder, 2026-09-29. Spec updated in the Environment section.

---

### DL-007 — Documentation review before the Phase 1 spikes: console and print logging

- **Status:** Confirmed, 2026-09-29. Developer's decision on ordering; findings are documentation-only, not live-tested.
- **Requirement:** before the other Phase 1 spikes, the first step is a review of the MacroQuest documentation to answer the question DL-006 left open: can MacroQuest write console or Lua `print()` output to a file, and does anything in the Logs folder capture it?
- **Design choices:** none yet. The finding narrows the first spike but does not settle it.
- **Implementation choices:** docs were read from docs.macroquest.org through a summarizing fetch tool, so passages below are summaries, not verbatim reads. A web-search summary claimed `/mqlog` is "the primary tool for writing console output to log files"; the `/mqlog` page itself contradicts that, so the page was used, not the summary.
- **Open:** findings from the docs: (1) `/mqlog <text>` logs only the text explicitly passed to it, to `MacroQuest.log` in `Logs` (`<macro>.mac.log` inside a macro); it does not capture other output. (2) `/mqconsole` (clear/toggle/show/hide) documents no file logging; its settings (ShowMacroQuestConsole, PersistentCommandHistory, MaxBufferLines, LocalEcho) do not either. (3) Lua docs: `print()` "has been redirected to write to the mq chat"; nothing about files, errors or tracebacks. (4) `mq.event` docs say the matcher text is "the same matcher text that everyone is used to from macro events"; they do not say which text sources feed it. Not established: whether `print()` output reaches any file, whether `mq.event` sees it, and how Lua errors are displayed. The docs are silent on all three, so they need a live test or a read of the MacroQuest source. `CHANGELOG.md` in the MQ root has no log-related entries.
- **Source:** [/mqlog](https://docs.macroquest.org/reference/commands/mqlog/), [/mqconsole](https://docs.macroquest.org/reference/commands/mqconsole/), [Lua scripting](https://docs.macroquest.org/lua/), [Lua events and binds](https://docs.macroquest.org/lua/events-and-binds/), GitHub issue macroquest/macroquest#530.

---

### DL-008 — MacroQuest source review: print routing, event sources and logging

- **Status:** Confirmed as a reading of source, 2026-09-29. Not live-tested. Follows DL-007, whose documentation review left these questions open.
- **Requirement:** answer from the MacroQuest source, which the developer supplied at `references/MacroQuest Source` (git-ignored), what DL-007 could not: where Lua `print()` output goes, which text `mq.event` matches, and whether any of it reaches a log file.
- **Design choices:** none. The findings bear on spike 1 (whether the bridge can see other scripts' `print()` output) but the spike is not closed by them.
- **Implementation choices:** none.
- **Open:** findings, all from `src/`: (1) `print()` is replaced in `plugins/lua/bindings/lua_Globals.cpp:45` and calls `WriteChatColorf("%s", USERCOLOR_CHAT_CHANNEL, ...)`; `printf` does the same. (2) `WriteChatColor` (`main/MQ2Utilities.cpp:129`) calls `PluginsWriteChatColor` (`main/MQPluginHandler.cpp:813`), which returns early if `gFilterMQ` is set (the flag `/squelch` and `/filter mq` set), then calls every module's `WriteChatColor`. (3) The Lua plugin's `OnWriteChatColor` (`plugins/lua/MQ2Lua.cpp:2402`) passes the line to the event processor of every running, non-dead, non-paused script, including scripts other than the one that printed. `OnIncomingChat` (line 2421) does the same for EverQuest chat. So by the source, a catch-all `mq.event` in one script would see another script's `print()` output, and an event pattern would match it. (4) The only debug logging on that path is `DebugSpew`, whose file flag is false there, so it goes to `OutputDebugString` only. `DebugSpewAlways` writes `Logs\DebugSpew.log` when `/spewfile` or `DebugSpewToFile=1` is set. I did not check what calls `DebugSpewAlways`. (5) Lua errors are also written through `WriteChatColorf` in red (`LuaCommon.h:22`, `LuaThread.cpp:239`), so they reach event matchers by the same route. (6) `MQ2Lua` already installs its own traceback error handler (`LuaThread.cpp:223`) and stores tracebacks in the Lua registry; this is relevant to spike 3 and has not been examined further. (7) The one file logger found that a script can drive is `/mqlog` (per DL-007). Not established: the source checkout's version against the installed build (the source has no version marker I could find, the installed `MQ2Lua.dll` is dated 2026-08-29), whether `/echo` reaches `WriteChatColor` (spike 5), and behavior when the script that prints is itself paused or squelched beyond what the code above shows.
- **Source:** the files and lines cited above, in `references/MacroQuest Source/src`.

**Addendum to DL-008, 2026-09-29 — source vs installed build.** The developer noted `/echo ${MacroQuest.Build}` prints `4` in game. In the source, `${MacroQuest.Build}` returns `gBuild` (`src/main/datatypes/MQ2MacroQuestType.cpp:100`), the build *target*, not a version: `BuildTarget` in `include/mq/base/BuildInfo.h` is Live=1, Test=2, Beta=3, Emu=4. So `4` says the installed build is the Emu target (consistent with Project Triune) and says nothing about the version. `${MacroQuest.BuildName}` would print `Emu`. To compare versions, the installed `resources\CHANGELOG.md` was compared with the source's `data/resources/CHANGELOG.md`: identical apart from line endings, newest entry 6/23/2026. That is evidence the source and the install come from the same release notes, not proof the code is identical (a changelog can lag the code, and the installed binaries are dated 2026-08-29). Version match: probable, not proven.

**Second addendum to DL-008, 2026-09-29 — origin of the installed build.** The developer confirmed the installed MacroQuest came from the [rel-emu-rof2 release](https://github.com/macroquest/macroquest/releases/tag/rel-emu-rof2), by two routes: a browser history search (the only MacroQuest release page in the history), and the TAC release notes. TAC stopped bundling MacroQuest at [V1.7.2](https://github.com/gennro/TriuneAutocombat/releases?page=2#release-V1.7.2), and its release notes link to that same page, which is what prompted the developer to download MacroQuest directly. Status: confirmed by the developer from their own records; I did not verify it. What this does not settle: whether the source folder in `references/` is a checkout of that same release. That link rests on the changelog match in the first addendum and is unconfirmed by the developer.

**Third addendum to DL-008, 2026-09-29 — origin of the source folder.** The developer downloaded "Source code (zip)" from the rel-emu-rof2 release page and unzipped it into `references/MacroQuest Source` (the developer wrote `resources/`; the folder that exists is `references/`, taken here as a slip). Status: confirmed by the developer's account. Together with the second addendum, the install and the source both come from the same release page, and their changelogs match. One residual gap: the developer did not say whether the release was re-published between installing and downloading the source zip, and I did not check the release page. The matching changelog is the evidence against that, not proof. Source-based findings in DL-008 are treated as applying to the installed build, still subject to live confirmation.

---

### DL-009 — Output capture is the bridge's job, because MacroQuest writes no log

- **Status:** Confirmed, 2026-09-29. Developer's decision, after the documentation review (DL-007) and source review (DL-008).
- **Requirement:** MacroQuest does not write console or Lua `print()` output to any file, so nothing Claude needs to read from that output can come from a MacroQuest log. Whatever Claude needs to read must be captured in Lua and written by our own code. This is why SPEC.md's bridge writes `events.jsonl`; the finding confirms that design rather than changing it. The review of the logs question is closed.
- **Design choices:** none new. The existing design already has the bridge (and the runner and `testlog`) append observed output to `events.jsonl`. EverQuest logs, which do exist on disk, are still read directly.
- **Implementation choices:** none decided here.
- **Open:** closing the review does not close spike 1. The source says the bridge's `mq.event` matchers should see other scripts' `print()` output, but that has not been observed live. If it fails live, the spec's fallback applies: the runner and `testlog` write to `events.jsonl` directly. Also noted, not yet examined: SPEC.md's spellspree section says that script's own notes found `mq.event` did not fire for "You give…" or scribe lines but did for vendor price tells, which bears on spikes 1 and 5.
- **Supersedes:** nothing. Consistent with SPEC.md "MQ-side bridge (Lua)".
- **Source:** DL-006, DL-007, DL-008; developer statement, 2026-09-29.

---

### DL-010 — Spike 1 result: a catch-all `mq.event` hears other scripts' `print()` output

- **Status:** Confirmed live, 2026-09-29, one run on the developer's installed build (rel-emu-rof2, per DL-008 addenda). Single observation, not a repeated test.
- **Requirement:** answer the first Phase 1 spike: does a catch-all `mq.event` see `print()` output from other Lua scripts, or only EverQuest chat? Result: it sees it.
- **Design choices:** none changed. SPEC.md's primary path holds (the bridge's catch-all event feeds `events.jsonl`); its fallback (the runner and `testlog` write directly) is not needed for this purpose.
- **Implementation choices:** the test used two throwaway scripts in `MacroQuest\lua` (`spike1_listener.lua`: `mq.event('spike1_all', '#*#', ...)`, writing lines containing `SPIKE1` to a file, with `mq.doevents()` in a 100 ms loop; `spike1_sender.lua`: `print`, `printf`, then `mq.cmd('/echo ...')`, 500 ms apart). The listener's pattern `#*#` matched, which is the catch-all pattern this design needs.
- **Open:** (1) Observed in `Logs\spike1_events.txt`: `09:01:55 | SPIKE1-A print() from a different script`, `09:01:56 | SPIKE1-B printf() from a different script`, `09:01:57 | SPIKE1-C /echo control line`. All three arrived, matching the source reading in DL-008. (2) Line C shows an `/echo` issued with `mq.cmd` from a script also reaches the event matchers. That is early evidence for spike 5 but not its answer, since spike 5 concerns an echoed line shaped like an EverQuest tell, typed by the user or sent by the bridge. (3) Not checked: events from a paused script, squelched output, and very high print rates (dropped or reordered lines). (4) The developer did not report whether red error text appeared in game; I did not ask.
- **Supersedes:** nothing. Resolves the open item in DL-008 that spike 1 needed live confirmation.
- **Source:** `Logs\spike1_events.txt` (contents above), read by Claude after the developer ran the test.

**Addendum to DL-010, 2026-09-29 — console screenshot from the same run.** The developer reported no red error text appeared, and supplied a screenshot of the MQ chat window, which closes DL-010 Open item (4). The console showed, in order: `Running lua script 'spike1_listener' with PID 32`, `Running lua script 'spike1_sender' with PID 33`, the three `SPIKE1-` lines, `Ending lua script 'spike1_sender' with PID 33 and status 0` (the sender finished on its own), `No lua script matching "spoke1_listener" was found` (a typo in the developer's first stop command, so that stop did nothing), then `Ending running lua script 'spike1_listener' with PID 32` and `Ending lua script 'spike1_listener' with PID 32 and status -1` (the corrected stop). The typo did not affect the result, since the listener kept running until the corrected stop. Relevance to spike 2: these are messages `/lua` printed, showing a normal finish as status 0 and a manual stop as status -1. They are not values read from `${Lua.Script[name].Status}`, which spike 2 asks about and which remains unchecked. Also note: the `/lua` start/stop messages are themselves chat lines and would reach the bridge's catch-all event.

---

### DL-011 — Spike 2 result: what `${Lua.Script[...]}` reports on this build

- **Status:** Confirmed live, 2026-09-29, one run of `spikes/spike2_run.mac` on the developer's installed build, read from `Logs\spike2_status.txt` (recorder polling every 250 ms, logging changes) plus the MQ console as shown in the developer's screenshots. An earlier run failed because the recorder had a path-escaping fault of Claude's making (LL-001), so only the second run has recorder data.
- **Requirement:** answer spike 2: the exact values of `${Lua.Script[name].Status}`, and whether they can tell a finished script, a stopped script and a crashed script apart.
- **Design choices:** none made here. One conflict with the spec is raised in Open and needs the developer's decision.
- **Implementation choices:** none.
- **Open:** Observed: (1) `Status` returned `RUNNING`, `PAUSED` and `EXITED`. `STARTING` was never observed (a script first appeared as `RUNNING`; a 250 ms poll may simply miss it). (2) Pause and resume showed as `PAUSED` then `RUNNING` within the poll interval. (3) A script that finished by itself (PID 46), one stopped with `/lua stop` (PIDs 45, 47) and one that crashed with a Lua error (PID 48) all ended as `EXITED`. Only the finished one had return values (`ReturnCount=2`, `Return` = `function: 0x00ce4258,target-done`, meaning the first "return value" is the chunk function itself and the script's own value is item 2). The stopped and crashed scripts showed `ReturnCount=0`, indistinguishable from each other through the TLO. The `/lua` console message also ended a crash and a manual stop with the same `status -1`; a natural finish showed `status 0`. (4) No `error` status exists in the TLO on this build; the source agrees (`LuaThread.h:48`: Starting, Running, Paused, Exited). (5) A crash does print red chat lines (`... SPIKE2 deliberate error`, `stack traceback:`, function and line), which by DL-010 the bridge's catch-all event should be able to hear; not yet tested with a real listener. (6) Look-up by name returned the current run of that name once it restarted, and by PID the old entry then returned nil. The source explains it: starting a script whose name has run before erases the old entry (`MQ2Lua.cpp:590`), so there is one entry per name and no stale-entry ambiguity. A script already running is not started again (`MQ2Lua.cpp:582`): `/lua run` on a running script prints "already running" and creates no new PID, so a reload must stop it first. (7) `${Lua.PIDs}` listed running and paused scripts and dropped exited ones; it always included PID 1, a script that was already running in the developer's session (not identified). Not tested: a name that has never run, `STARTING`, behavior after a stop that has not yet completed.
- **Conflict for the developer (Protocol §1, not changed):** SPEC.md lines 84 and 101 say `lua_status` "detects crashed or finished scripts" and reports "running, finished or crashed" with the last error. Observed, `Status` cannot separate a crash from a stop. Possible sources for crash detection are the red error chat lines (spike 1 shows they reach the event matchers) or the runner's `pcall` (spike 3). Which to rely on is a design decision, not made here.
- **Supersedes:** nothing yet; the spec lines above are unchanged pending the developer's decision.
- **Source:** `Logs\spike2_status.txt`, MQ console screenshots, `references/MacroQuest Source/src/plugins/lua/MQ2Lua.cpp` and `LuaThread.h`.

**Addendum to DL-011, 2026-09-29 — crash-detection decision deferred.** The developer decided to wait until spike 3 is done before choosing how the bridge detects a crashed script, since the choice depends on whether the runner's `pcall` works. Revisit trigger: spike 3's result is recorded. SPEC.md lines 84 and 101 stay as written until then.

---

### DL-012 — Spike 3 result: a runner can wrap a script in `xpcall` without changing its behavior, and it changes what MacroQuest reports about a crash

- **Status:** Confirmed live, 2026-09-29, one run of `spikes/spike3_run.mac` on the developer's installed build, read from `Logs\spike3_log.txt` (saved as `spikes/spike3_log.txt`) plus the developer's console screenshot.
- **Requirement:** answer spike 3: can the runner wrap a script's main loop in `pcall` without changing its behavior, for capturing tracebacks?
- **Design choices:** none made here. It unblocks the crash-detection decision deferred in DL-011.
- **Implementation choices:** the test runner loads the target with `loadfile` and runs it under `xpcall(chunk, debug.traceback)`. It does not use `require`, because the source (`lua_MQBindings.cpp:98`) makes `mq.delay` error inside a `require`d module ("Cannot delay while importing a module").
- **Open:** Observed: (1) Same target, run directly (A) and through the runner (B): identical tick timing (500 ms), `mq.event` handler fired on the mid-run `/echo`, `mq.doevents()` worked, and the return value (`spike3-return`) came back to the runner. `mq.delay` works through `xpcall`. (2) A target that errors after a delay (C): the runner caught it and logged the message plus a traceback naming the target file and line. (3) The console showed no red error text for case C, and its exit line read `status 0`. So a wrapped crash looks like a clean exit to MacroQuest and to `${Lua.Script[...].Status}`; the runner is then the only source of crash information and must report it itself. (4) `/lua stop spike3_runner` mid-run (D) stopped the target: ticks ended, console `status -1`. The runner logged nothing on a stop (no "caught", no "runner end"), so a stop is recognised by that absence plus `status -1`, not by a runner message. (5) The console names the running script as `spike3_runner`, not the target, so a status query by the target's name would not find the wrapped script; queries would use the runner's name or PID. Observed only in the console, not through the TLO. (6) Flaw in the test: the `SPIKE3_MODE` marker meant to tag lines `runner` did not reach the target (all target lines read `direct`). Runner lines bracket the target lines, so the conclusions above stand, but the marker is unreliable and was not investigated. Not tested: an error before the target's first yield, an error inside an `mq.event` or `mq.bind` handler, ImGui, `os.exit` or `mq.exit` inside the target, and `mq.delay` with a condition. From the source (`LuaEvent.cpp:445`, not tested live), event handlers run in their own coroutines, so an error inside one probably would not reach the runner's `xpcall`.
- **Supersedes:** nothing. Unblocks the decision recorded in DL-011's addendum.
- **Source:** `Logs\spike3_log.txt`, the console screenshot, `lua_MQBindings.cpp`, `LuaEvent.cpp`.

---

### DL-013 — Spike 3b result: a catch-all listener hears Lua crash text, including crashes in event and bind handlers

- **Status:** Confirmed live, 2026-09-29, on the developer's installed build. The developer ran `spikes/spike3b_run.mac` twice (the first run's console text was lost when the MQ window was resized; the listener truncates its log on start, so `Logs\spike3b_log.txt`, saved as `spikes/spike3b_log.txt`, holds the second run only). The second run's log and the developer's console screenshot agree, and the console text matches the log.
- **Requirement:** gather the evidence DL-011's deferred crash-detection decision was waiting on: can the bridge's catch-all listener (spike 1) hear a Lua error, and how does each kind of crash show up?
- **Design choices:** none made here. The decision is still the developer's (see Open).
- **Implementation choices:** none.
- **Open:** Observed: (1) A crash in a script's main chunk (`crash_main`): the listener received one chat line holding the error message, `stack traceback:` and the frames, with the line breaks removed (`...main chunk errorstack traceback:<tab>[C]: in function 'error'<tab>...`). The console shows it as several red lines; the event line arrives as one string with no separators, so parsing must not depend on newlines. The line names the script file and line number. It was followed by `Ending lua script '<name>' with PID N and status -1`, and `Status` went to `EXITED`. (2) A crash inside an `mq.event` handler and inside an `mq.bind` handler: the listener heard the same kind of line, ending with `in function <file:line>` naming the handler. In both cases the script kept running: its ticks continued to the end, it finished normally with `status 0`, and `Status` stayed `RUNNING` until it did. So handler crashes are visible only through the error text, not through status or the exit line. (3) The same pattern held in spike 2's crash (DL-011) and here: a crash prints the error text, then an `Ending lua script ... status -1` line with no preceding `Ending running lua script ...` line, while a manual stop prints `Ending running lua script ...` first. Three crashes and two stops are consistent with this; it is an observed pattern, not a documented one. (4) The MQ console window loses its text when resized, another reason the console cannot serve as the record (DL-009). Not tested: crashes in scripts that yield in a condition delay, several crashes in quick succession, error text from a script the runner wraps (DL-012 showed the runner hides it), whether the exact wording is stable across MacroQuest versions, and whether a script that merely prints text resembling an error would be mistaken for a crash.
- **Decision for the developer (Protocol §1, §17, not made):** how the bridge detects a crashed script (SPEC.md lines 84 and 101). Evidence so far: the chat listener saw all three crash kinds with no change to the script under test; the runner (DL-012) catches only a crash in the wrapped main body, hides it from MacroQuest, changes the name a status query sees, and has not been shown to catch handler crashes.
- **Supersedes:** nothing yet.
- **Source:** `spikes/spike3b_log.txt`, console screenshot, DL-010, DL-011, DL-012.

---

### DL-014 — Crash detection uses the error text; the runner is out of v1

- **Status:** Confirmed, 2026-09-29. Developer's decision, on Claude's recommendation. SUPERSEDES SPEC.md's error-capturing runner and its `lua_status` crash claims (spec lines edited to match, each marked or pointing here).
- **Requirement:** the bridge must be able to tell that a script under test crashed, and report the file, line and stack. This is met by the catch-all listener hearing the error chat line (DL-010, DL-013), covering crashes in the main chunk and in `mq.event` and `mq.bind` handlers, with no wrapper around the script under test.
- **Design choices:** no `claudebridge/runner` in v1. `lua_run` and `lua_reload` start and restart scripts directly with `/lua run` and `/lua stop`. `lua_status` reports `Status` (`RUNNING`, `PAUSED`, `EXITED`) plus any crash seen in the error text. The opt-in `testlog` module is unchanged by this decision.
- **Implementation choices:** how the bridge recognises and parses the error line, and how it ties a line to a script by file name, are not decided. Two observed signals (DL-013 Open (3)): the error text itself, and the exit line pattern for main-chunk crashes.
- **Open:** the reasons the runner was set aside: it catches only a crash in the wrapped main body, hides it from MacroQuest (exit `status 0`, no red text), changes the name a status query sees (DL-012), and has not been shown to catch handler crashes, while the listener needs no change to the script under test. Risks accepted by the developer: dependence on MacroQuest's error wording, and a script that prints error-like text could be mistaken for a crash; neither tested. Revisit trigger: a real need turns up (the developer's words), for example a crash the listener misses.
- **Supersedes:** SPEC.md `claudebridge/runner` design and lines for `lua_run`, `lua_reload` and `lua_status`, and the "Error capture" paragraph, and DL-011's deferred decision.
- **Source:** DL-011, DL-012, DL-013; developer statement, 2026-09-29.

---

### DL-015 — Spike 4 result: the `mcp` Python SDK installs and works on Python 3.14

- **Status:** Confirmed locally, 2026-09-29. Ran on the developer's machine in a throwaway virtual environment outside the repo. Local validation only: not run under Claude Code's `.mcp.json` launch, and no MacroQuest involvement.
- **Requirement:** answer spike 4: does the `mcp` Python SDK install cleanly on Python 3.14, which the MCP server depends on? Result: yes.
- **Design choices:** none. The fallback (a separate Python 3.12 or 3.13 install) is not needed.
- **Implementation choices:** none decided here. The SDK version to use (2.x as installed, or a `mcp<2` pin) is left open.
- **Open:** Observed: (1) Python is 3.14.7, 64-bit (`python --version`, `py -0p`), so the spec's "3.14.7" is now confirmed. (2) `pip install mcp` installed `mcp` 2.2.0 with its dependencies (including `pydantic` 2.13.5, `starlette`, `uvicorn`, `pywin32`); `pip check` reported no broken requirements. (3) A minimal stdio server (one `add` tool) and a client in the same environment listed the tool and returned `add(2,3) -> 5`. (4) `mcp` 2.x is a breaking version: `from mcp.server.fastmcp import FastMCP` fails with an error saying FastMCP was renamed `MCPServer` (`from mcp.server.mcpserver import MCPServer`), and the error points to a migration guide or pinning `mcp<2`. My first test server used the old name and failed until corrected; that was a test-code error, not an install failure. The test files are `spikes/spike4_server.py` and `spikes/spike4_client.py`. Not tested: launching from `.mcp.json` in Claude Code, long-running behavior, and Windows specifics beyond the round trip. Because 2.x is a recent breaking release, the eventual MCP server should pin an exact version; that is an implementation choice for Phase 1.
- **Supersedes:** nothing.
- **Source:** command output from the test run, 2026-09-29; the SDK's own error message about the rename.

---

### DL-016 — Spike 5 result: a fake tell fires `mq.event`, so autoinv's tell path is testable with one character

- **Status:** Confirmed live, 2026-09-29, one run of `spikes/spike5_run.mac` on the developer's installed build, read from `Logs\spike5_log.txt` (saved as `spikes/spike5_log.txt`) and the developer's console screenshot. autoinv was not running.
- **Requirement:** answer spike 5: can an `/echo` of a fake tell fire `mq.event`? Result: yes. This is the deciding factor named in DL-005 for whether most of autoinv's Phase 1 tests run with one character.
- **Design choices:** none changed. The spec's Phase 1 autoinv tests marked "(if injection works)" are now Phase 1 without the condition (spec edited; DL-005's open item is resolved by this entry).
- **Implementation choices:** the test listener used autoinv's own patterns and callback shape (`"#1# tells you, '#2#'"`, `"#1# has left the group."`, `lua/autoinv.lua` lines 576 to 592), with a raw catch-all beside them.
- **Open:** Observed, all lines reached both the pattern event and the raw catch-all: (1) `Spikefive tells you, 'inv'` echoed by the macro gave sender `Spikefive`, body `inv`; likewise `'INV'` (body `INV`), `' inv '` (body ` inv `, spaces preserved) and `'inv please'`. (2) The same tell sent from a script with `mq.cmd("/echo ...")` and with `print()` also fired the event with the same captures, so the bridge can inject with `mq.cmd`. (3) `Spikefive has left the group.` fired the group-leave pattern with player `Spikefive`, from both the macro and a script. Not established: that a real tell from another player arrives as the identical text (Phase 2's live invite test covers it), the `/invite` that autoinv would send to a name that is not online (harmless per the spec, but autoinv was not run), and whether an injected tell could be confused with a real one by anything in autoinv or the bridge.
- **Supersedes:** nothing. Resolves DL-005's Open item.
- **Source:** `spikes/spike5_log.txt`, console screenshot, `lua/autoinv.lua`.

---

### DL-017 — Phase 0 gate ("setup confirmed") declared passed

- **Status:** Confirmed, 2026-09-29. Developer's decision.
- **Requirement:** SPEC.md's roadmap gate G0, "setup confirmed", stands passed. What it rests on: the log and script paths confirmed on disk and readable (DL-006), the MacroQuest documentation and source reviews (DL-007, DL-008), and the five Phase 1 spikes resolved (DL-010 to DL-016). Phase 1's build (`claudebridge`, `mq-mcp`, the test runner, the guardrails) may now be planned.
- **Design choices:** none new.
- **Implementation choices:** none.
- **Open:** passing the gate is not the same as validating the design. Each finding rests on one run on the developer's installed build, with edge cases listed as untested in its own entry. The bridge itself is unbuilt and untested. The autoinv log path (`config\AutoInvite\autoinvite.log`) is still unchecked on disk. Phase 1's own gate is separate ("spellspree suite passes unattended; kill switch tested").
- **Supersedes:** nothing.
- **Source:** developer statement, 2026-09-29; DL-006 to DL-016.

---

### DL-018 — Phase 1, slice 1 (read-only bridge and MCP path): acceptance criteria

- **Status:** In progress, 2026-09-29. Criteria are added here as the developer approves each one. Nothing is built for this slice yet.
- **Requirement:** slice 1 is the first build of Phase 1: `claudebridge` with the file transport, `heartbeat.json`, `events.jsonl` fed by the catch-all listener, and the read-only commands `ping`, `eval`, `eval_many`; plus a minimal `mq-mcp` with `mq_status` and `mq_eval`. Nothing in it can change the game. The developer chose this order after confirming the spikes proved individual parts but not the assembled path (no spike touched the file transport, `mq.parse`, a JSON library, a `.mcp.json` launch, or the two-process setup). The developer approved the following criteria, one at a time:
  1. **`ping` over the file transport.** With `claudebridge` running, writing `inbox\<seq>.json` with the command `ping` produces `outbox\<seq>.json` with the same sequence number, containing the bridge version, character name, zone and bridge state. Source: SPEC.md "MQ-side bridge (Lua)". Checked locally by running the request-handling logic against a fake game; the real transport and the real character and zone values are live-only. No reply-time limit is set (any value would be a first guess, Protocol §15).
- **Design choices:** request-handling logic kept separate from the MacroQuest-facing code so it can be tested locally (Protocol §20).
- **Implementation choices:** none decided.
- **Open:** further criteria still to be settled (see later addenda).
- **Supersedes:** nothing.
- **Source:** SPEC.md; DL-010 to DL-016; developer approval, 2026-09-29.

**Addendum to DL-018, 2026-09-29 — criterion 2 approved.** The developer approved the following exactly as written, with its last sentence as an Assumption:

2. **The bridge only handles complete requests, in order.** The bridge ignores any request file still under its temporary name. It handles complete requests strictly in sequence-number order, one at a time. If a sequence number is missing while a later-numbered request is present, later requests wait and are not handled. While blocked by such a gap, `heartbeat.json` shows `waiting_for_sequence: <n>`. **Assumption:** the bridge does not handle a request whose sequence number is at or below the highest sequence number it has already completed. It stays an Assumption because how the bridge durably knows its highest completed number across a restart is not yet defined.
   - Source: SPEC.md "MQ-side bridge (Lua)" (temp-name-then-rename; "the next sequence number"). Checked locally with temp-named and out-of-order files in a fake inbox; the real rename on the developer's Windows setup is live-only.
   - Reasoning recorded with it: skipping a gap could silently run later commands in the wrong state and make a bad test run look valid, so the bridge never skips. The wording "while a later-numbered request is present" separates a real gap from the normal state where the next request has not been written yet. "Completed" was chosen over "handled" so the `cmd` slice can define its own started/uncertain state without stretching this sentence.
- **Deferred to other slices, each with a specific trigger:** (a) the rule that a request with no reply within the caller's timeout marks the test run `INVALID/INFRASTRUCTURE`, with no automatic retry and no further test commands in that run, belongs to the test-runner slice (slice 1 has no `run_test`); (b) a "started" marker written before each `cmd` runs, so a restart can tell "executed, reply not written" from "never executed", belongs to the `cmd` slice; (c) the bridge's durable knowledge of its highest completed sequence across a restart, and recovery after a lost request, are unsettled and belong with startup and recovery state. The developer did not want gaps filled with made-up requests.

**Addendum to DL-018, 2026-09-29 — criterion 3 approved.** The developer approved the following, with the word "successfully" added to the first sentence:

3. **The MCP server never reuses a sequence number.** A sequence number becomes allocated only when a fully written request is successfully published. Once allocated, it is never used for a different request. That holds across timeouts, MCP server restarts, and cleanup of old files.
   - Source: follows from criteria 1 and 2 and SPEC.md's file transport; it is the MCP-side half of the gap protection. Checked locally by simulating a restart between requests, wiping old `inbox` and `outbox` files and then restarting (the next number must exceed every number used before, so the invariant cannot depend on those folders keeping history), and a crash while a request is still being written (it must leave no numbered file). The real rename and folders are live-only.
   - Reasoning recorded with it: "successfully" removes ambiguity about whether a number was allocated when a rename or publish attempt failed and no numbered request ever became visible.
   - Design choices, kept out of the requirement and decided when built: a unique temporary file name (`request-<uuid>.tmp`), a persistent counter file, taking the higher of the counter and the highest number found in the folders, reconciling at startup, and never deleting request or reply files during a run. Ordering rule noted for the counter file: written before the rename, a crash burns a number (a gap); written after, a crash leaves it stale and the next request could reuse a number, which is why the higher-of rule is proposed.

**Addendum to DL-018, 2026-09-29 — criterion 4 approved.** The developer approved the following as pasted (approval language, no request for Claude's thoughts):

4. **`eval` preserves MacroQuest's parser result.** An `eval` request with a TLO expression, such as `${Me.PctHPs}`, produces a reply containing the original expression and the exact string value returned by `mq.parse`. The bridge does not reinterpret, trim, normalize, or translate that value. `NULL` remains `NULL`, and an empty string remains empty.
   - Source: SPEC.md command set (`eval` runs an expression with `mq.parse` and returns the string). "Unchanged" was narrowed to the parser's returned string value, not the whole reply payload. Checked locally by building the reply from whatever a fake parser returns, including empty and `NULL`-style strings; real values are live-only.
   - **Open (approved as open):** (1) what `mq.parse` returns for an unknown expression on this build (no spike used `mq.parse`); (2) whether any TLO member, including plugin TLOs, can change game state, so the spec's "read-only" label is not assumed as fact.
   - **Open (raised by Claude, not yet discussed with the developer):** (3) how values containing control bytes or bytes that are not valid UTF-8 (EverQuest text can include the `0x12` item-link marker) are carried in the JSON reply unchanged. The requirement is that they arrive byte for byte after decoding; escaping or base64 are candidate mechanisms. Whether the JSON library to be vendored passes bytes above 127 through unescaped is unverified.

**Standing rule on pasted text, 2026-09-29 (developer):** pasted text that contains approval language is the developer's approval; the developer will not paste approval language they do not agree with. Exception: if the developer asks Claude for its thoughts or for pushback on the pasted text, any approval language in it was included in error and is not approval. Claude may always ask explicitly whether approval is given if anything the developer does contradicts this.

**Addendum to DL-018, 2026-09-29 — criterion 5 approved.** The developer approved the following:

5. **`eval_many` returns a list of answers in one reply.** An `eval_many` request with a list of expressions produces one reply. For each expression, in the order given, the reply contains the original expression and the exact string value returned by `mq.parse`, under the same preservation rules as criterion 4.
   - **Assumption:** the expressions in one request are evaluated in one uninterrupted run of the bridge script, with no yield between them. From the source, that is a single stretch inside one MacroQuest pulse (`MQ2Lua.cpp:1982`: each script's `Run()` is called from `OnPulse` and continues until it yields). That game state cannot change during that stretch is not verified.
   - **Open:** (1) the reply for an empty list (the developer's reviewer leans toward a successful reply with an empty result list; spec is silent); (2) whether the list has a maximum size, left unbounded until there is a reason.
   - Source: SPEC.md command set (`eval_many`, "snapshots for assertions"). Checked locally with a fake parser for order and unchanged values; real values are live-only. Correction noted: a pasted review said the no-yield behavior was "verified", but the bridge is not built yet, so that behavior is a design intent, not a verified fact. The Assumption above is worded so it does not claim otherwise; it becomes locally checkable once the bridge exists.

**Addendum to DL-018, 2026-09-29 — criterion 6 approved.** The developer approved the following as worded:

6. **The bridge shows that it is alive with `heartbeat.json`.** While `claudebridge` is running, it updates `heartbeat.json` about once per second, as SPEC.md states. The heartbeat contains the character name, zone and bridge state, and gives enough freshness information for a reader to tell when it was last updated. During a sequence gap it also contains `waiting_for_sequence`, as defined in criterion 2. A reader must never observe a partially written heartbeat.
   - **Open:** (1) the set of bridge-state values (slice 1 has no halt, and no enum is invented until there are real state transitions to represent); (2) how character and zone are represented when no character is in the game; (3) the age at which the MCP server treats a heartbeat as stale (a timeout policy for the MCP side, not this criterion); (4) the tolerance that "about once per second" allows (a first guess under Protocol §15 until there is evidence).
   - **Design choices:** how freshness is encoded (an explicit timestamp is preferred over relying on file modification time, for ease of inspection); how atomic publication is done (temp write then same-folder rename is preferred).
   - Source: SPEC.md "MQ-side bridge (Lua)". Checked locally with a fake game (fields present; `waiting_for_sequence` only during a real gap) and with a separate reader process reading in a loop while the writer updates, where every read must parse as valid JSON; the real once-a-second cadence, character and zone are live-only.
   - Reasoning recorded with it: the timestamp and atomic-replace points, first proposed as Assumptions, were reclassified (freshness and no-partial-read are the requirements; the mechanisms are design choices). "Approximately once per second" was kept because the spec says every second and a pulse-driven loop cannot hit it exactly; the tolerance is left Open rather than loosening the spec silently.

**Addendum to DL-018, 2026-09-29 — criterion 7 approved.** The developer approved the following as worded:

7. **The bridge records observed events in `events.jsonl`.** Every event the bridge records is appended to `events.jsonl` in observation order, as one JSON object on its own line. For events containing text, that text is preserved under the same rules as criterion 4. Every line received through the catch-all listener is recorded, and the bridge may record other events too. Each completed event has an increasing event number that can serve as a cursor for later event retrieval. A reader must not treat an incomplete trailing line as a completed event.
   - **Open:** (1) whether slice 1 classifies crash text as an error event or an ordinary line (DL-014 left recognition to implementation); (2) how the file is kept from growing forever; (3) behavior at very high event rates (spike 1 did not test it); (4) how a fragment left by an interrupted append is detected and handled, including when the bridge next starts (an unhandled fragment could be glued to the next event and become a corrupt line in the middle of the file); (5) whether event numbering continues across a bridge restart, and whether the file is truncated at start (restarted numbering would make a cursor ambiguous).
   - **Design choice:** whether events also include the time they were observed.
   - **Tested:** the reader rule is tested when the first tool that reads events exists; slice 1 has none. Until then it is a requirement on that future reader. Everything else is checked locally with fake events written to a temporary file (order, one object per line, text unchanged, numbers increasing), and live with real chat.
   - Source: SPEC.md "MQ-side bridge (Lua)" (`events.jsonl`, the `chat_since` cursor); DL-010 and DL-013 (the catch-all hears `print()` output, `/lua` messages and crash text). Reasoning recorded with it: the requirement does not name the listener as the only source, because the spec's script start and exit and error events may be generated by the bridge; the event number is a requirement because the specified `chat_since` needs a cursor and adding numbers later would change the file format.

**Addendum to DL-018, 2026-09-29 — criterion 8 approved.** The developer approved the following as worded:

8. **`mq_eval` returns values unchanged and never resends.** Calling `mq_eval` with one or more expressions sends one request to the bridge and returns, in the order requested, the exact string values contained in the bridge reply, under the same preservation rules as criterion 4. A single expression uses `eval`; multiple expressions use `eval_many`. If no reply arrives within the tool's timeout, `mq_eval` returns an error and does not resend that request.
   - **Open:** (1) the timeout length (a first guess under Protocol §15, left unset until there is evidence); (2) the shape of the returned error; (3) whether `mq_eval` sends a request when the heartbeat looks stale, which depends on the stale threshold (criterion 6, Open 3); (4) what the server does with concurrent tool calls (serialize, allow several outstanding numbered requests, or reject), and when each timeout clock starts. Concurrent calls are realistic because Claude can issue several tool calls at once.
   - **Depends on:** criterion 4's Open (3), for byte-for-byte fidelity through the MCP tool result (another hop that could alter control or non-UTF-8 bytes). The tool's input schema must require at least one expression, otherwise criterion 5's empty-list question returns.
   - Source: SPEC.md MCP tool table (`mq_eval`), criteria 1 to 5, and the lost-request decisions under criterion 2. Checked locally with a fake bridge folder and a scripted responder (request written under criterion 3's numbering, reply values returned unchanged; a silent responder gives a timeout error and exactly one request in the inbox, never two); live with the real bridge.

**Correction to earlier reasoning, added to criterion 3's design notes, 2026-09-29.** Claude earlier said that with a single writer "no race" is possible and no locking is needed. That holds only if the MCP server serializes number allocation and the publishing rename as one step inside the process. Claude can issue concurrent tool calls, so two calls in one server could otherwise choose the same number. Criterion 3's requirement (a number is never reused) is unchanged; this is a constraint on its mechanism: allocation plus publish is one serialized step.

**Design note added to criterion 6, 2026-09-29 — replacing `heartbeat.json` on Windows is not a plain rename.** Found while reviewing criterion 9, tested locally on the developer's machine with `spikes/renametest.lua` (standalone LuaJIT, the same runtime family as MacroQuest's Lua, not MacroQuest's embedded copy) and a Python check: (1) Lua's `os.rename` onto an existing file fails (`File exists`); the old file stays. (2) `os.remove` on a file that a reader holds open fails (`Permission denied`). (3) Python's `os.replace` onto a file that a Python reader holds open fails (`Access is denied`). So the temp-then-rename mechanism preferred for criterion 6 cannot replace an existing heartbeat in Lua without either removing it first (a moment with no file, and a failure if a reader has it open) or another mechanism; and a reader holding the file open, even briefly, can make the writer's update fail. The requirement (a reader never sees a partial heartbeat, updated about once per second) is unchanged; this is a risk to its mechanism, to be resolved when the bridge is built. The criterion's reader-loop test would catch it. Not tested: whether MacroQuest's embedded Lua behaves the same, and whether an FFI or other route to an atomic replace is available inside it. Criterion 3 (new file names, no existing destination) is not affected.

**Addendum to DL-018, 2026-09-29 — criterion 9 approved.** The developer approved the following (the reviewer's wording, with the note that the age limit is a first guess under Protocol §15 kept on Open 1):

9. **`mq_status` reports game and bridge state.** `mq_status` reports whether an EverQuest game process is running and whether the bridge is alive. Bridge liveness is determined from the age of `heartbeat.json` against a configured age limit. The tool reports the age of the most recent heartbeat it can read. If no heartbeat can be read, `mq_status` says so. When the bridge is alive, it also reports the character, zone and bridge state from that heartbeat.
   - **Open:** (1) the age limit's value and where it lives in `config.toml` (a first guess under Protocol §15); (2) how the game process is detected (this session showed it as `eqgame`; the spec does not say how); (3) whether stale character, zone and bridge-state values are returned and, if so, how they are marked as last-known or stale; (4) multiple game instances, which remain out of scope for v1.
   - **Depends on:** criterion 6's Open (3), the stale-heartbeat threshold.
   - Source: SPEC.md MCP tool table (`mq_status`: "Is the game running, is the bridge alive, who and where is the character"). Checked locally with fake heartbeat files (fresh, old, missing) and a fake process list; the real process and heartbeat are live-only. The two checks use different sources on purpose (process presence for the game, heartbeat freshness for the bridge), so a contradiction between them is visible.

**Update to the criterion 6 design note, 2026-09-29.** "Temp-then-rename preferred" for `heartbeat.json` is demoted to a candidate mechanism: it is known to fail in standalone LuaJIT on Windows when replacing an existing or open file, and MacroQuest's embedded Lua is untested. This does not show atomic publication is infeasible; alternatives (a two-slot scheme, newest-file naming with cleanup of old files, a reader-tolerant scheme) remain design work. A pointer file has the same replace problem one level up. A reader-tolerant scheme would move the guarantee from the file to the reader, and criterion 6's wording ("a reader must never observe a partially written heartbeat") would then need to say which side holds it; not decided. Whether MacroQuest's embedded Lua can replace a file atomically can be checked with a short live test before a mechanism is chosen. This update is design-level and was not separately put to the developer for approval.

**Addendum to DL-018, 2026-09-29 — criterion 10 approved.** The developer approved the following as worded:

10. **Slice 1 only executes allowed request types, and an invalid request cannot block the queue.** In slice 1, the bridge executes only `ping`, `eval` and `eval_many`. A request that names any other command, or whose numbered request file can be read but cannot be parsed as a valid request, produces an error reply with the same sequence number and executes nothing. That request then counts as completed for the ordering rule in criterion 2. A numbered request file that cannot be read yet is left for the next poll and is not treated as a bad request.
   - **Open:** (1) the shape of the error reply, which must at least distinguish an unsupported command from a malformed or invalid request; (2) inbox files whose names are not a valid `<seq>.json`, kept separate from malformed numbered requests, ignored and logged until decided, along with the exact name format (for example zero padding); (3) how a numbered file that stays unreadable is made visible, without inventing a time limit (any limit would be a first guess under Protocol §15).
   - **Note:** this limits the command surface only. It does not prove `eval` is side-effect-free (criterion 4, Open 2).
   - Source: SPEC.md guardrails table ("Outside a test run, only read-only requests work", "Read-only by default"). Checked locally with a fake game that records every command it is asked to run (an unknown command such as `cmd` gets an error reply and nothing is run; unreadable JSON gets an error reply and the next request is still handled in order); the real bridge with a real bad file is live-only. Reasoning recorded with it: the unreadable-versus-invalid distinction is there because the Windows rename test showed a file held open by another process can fail to open, and turning that into a permanent error reply would consume the number of a request that may be fine.
