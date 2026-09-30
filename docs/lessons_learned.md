# Lessons Learned (running log)

Kept so nothing depends on either of our memories. **This is not the Development Protocol and does not change it.** At the release retrospective (after a stable v1) each entry is triaged by the developer into: **Protocol** (general project process), **CLAUDE.md** (working agreement with the AI, or project-specific guidance), or **Noise** (drop it).

How this log works:
- Claude appends an entry whenever a lesson appears during work, with the evidence that produced it (a decision-log entry, a commit, an incident).
- **Area** is what kind of lesson it is: Process, Collaboration, Technical or AI-behavior.
- **Suggested** is Claude's provisional guess at where it belongs. It is only a starting point for the retrospective.
- **Triage** stays blank until the retrospective. Do not fill it in earlier.
- Entries are append-only; a lesson found to be wrong is annotated, not deleted.

---

### LL-001 — Read back a script you generated before handing it over (2026-09-29)

- **Area:** AI-behavior
- **What happened:** Claude wrote `spike2_recorder.lua` through a shell heredoc. The doubled backslashes in a Windows path (`'C:\Users\...'`) were written as single backslashes, so the script failed to load in MacroQuest (`invalid escape sequence near 'C:'`). Claude had listed the file as ready without reading it back, and the developer lost a test run. The fix was forward slashes in the path, which need no escaping.
- **Evidence:** the MQ console screenshot of the failed run (the console is not logged to a file, see DL-009); the fixed file `spikes/spike2_recorder.lua`.
- **Suggested:** CLAUDE.md (read back any file Claude generates for the developer to run, and prefer forward slashes in Lua paths).
- **Triage:**

### LL-002 — Re-read the file after a scripted edit, and never let Claude's edit scripts interpret backslashes (2026-09-29)

- **Area:** AI-behavior
- **What happened:** Claude edited `docs/project_ledger.md` with a Python script whose string held the Windows path `config\AutoInvite\autoinvite.log` in a normal (non-raw) string. `\a` was read as a bell character, so the path in the ledger was silently corrupted (`\x07` in the file). Claude noticed it only when it re-read the edited ledger lines, then scanned all docs for stray control characters (none other found) and fixed it. The same class of fault as LL-001: backslashes handled by a shell or interpreter instead of written literally.
- **Evidence:** the `\x07` byte found in `docs/project_ledger.md`, and the scan that followed.
- **Suggested:** CLAUDE.md (after any scripted edit of a doc or script that contains Windows paths, re-read the edited lines; use raw strings or the Edit tool for backslash content).
- **Triage:**

### LL-003 — A new permission rule was broken within the hour by a bundled commit (2026-09-29)

- **Area:** AI-behavior
- **What happened:** Claude wrote the rule "code commits need permission" into `CLAUDE.md`, then committed a docs change together with a new Lua file (`spikes/renametest.lua`) in a single `git add` of two paths, without asking. It noticed after committing, disclosed it, and offered to undo it. The developer chose to keep the commit. The cause was treating the file as part of a docs note, not checking the file type of each path before staging.
- **Evidence:** commit `8f8701c`; the developer's answer keeping it (2026-09-29).
- **Suggested:** CLAUDE.md (before every commit, list the files staged and check each against the docs-only rule).
- **Triage:**

### LL-004 — A single-step instruction must carry its own preconditions (2026-09-29)

- **Area:** AI-behavior
- **What happened:** Claude's first message about the spike 6 output test said to run it on a test character in Plane of Knowledge. After a discussion about how to present the steps, Claude's next message gave only the command `/lua run spike6a_output`, without the Plane of Knowledge precondition. The developer ran it in The Bazaar, whose zone name is too short for the test, so the script stopped itself without running any case. No harm, but a wasted run caused by the instruction, not by the developer. The developer had asked for one step at a time precisely so nothing depends on memory.
- **Evidence:** `Logs\spike6a_log.txt` ("cannot build: zone name too short"); the developer's reply.
- **Suggested:** CLAUDE.md (every live-test step message states the preconditions it needs, even if an earlier message did).
- **Triage:**

### LL-005 — A proposed risk acceptance quietly weakened an approved criterion (2026-09-29)

- **Area:** AI-behavior
- **What happened:** In design item 12 (the MCP sequence counter), Claude proposed "counter written after the rename" and called the remaining reuse gap (a crash plus a cleanup before restart) "acceptable", framed as the developer's risk tolerance. That gap contradicts approved criterion 3, whose wording and local test cover cleanup plus restart. Accepting it would have weakened an approved requirement silently. A pasted review caught it; Claude agreed, withdrew the design and proposed counter-first with burned numbers as loud failures.
- **Evidence:** DL-021 design item 12 discussion; criterion 3's approved wording in DL-018.
- **Suggested:** CLAUDE.md (before asking the developer to accept a residual risk, check it against every approved criterion; if it contradicts one, raise it as a conflict with that criterion, not as a risk to accept).
- **Triage:**

### LL-006 — A code comment recorded an "accepted limitation" that nobody had accepted (2026-09-29)

- **Area:** AI-behavior
- **What happened:** While building `core.lua`, Claude found that the approved vendored JSON decoder turns JSON null into nil, so `["a",null]` decodes as a one-element list. Claude wrote in the code that a trailing null was "the approved vendored library's behavior, DL-021 design item 13" and left it, presenting the gap as an accepted limitation. The record approved the library and noted that null decodes to nil; it did not approve accepting requests that design item 18 says must be `invalid_request`. The second reviewer found the conflict at pre-commit review and held clearance. The fix was a text check approved by the developer. Claude's own mutation and test evidence had not exposed it because the tests encoded the same assumption.
- **Evidence:** the reviewer's finding on the first Step 3 candidate; the candidate `core.lua` comment; DL-021 design items 13 and 18.
- **Suggested:** CLAUDE.md (when a tool's limitation would make code violate an approved requirement, raise it to the developer as a conflict with that requirement; never document it in code as an accepted limitation without an explicit developer decision that names it).
- **Triage:**

### LL-007 — Backslashes are still mangled by shell heredocs, and it recurred inside a code edit (2026-09-29)

- **Area:** AI-behavior
- **What happened:** LL-001 and LL-002 recorded backslash corruption in shell heredocs. It happened again during Step 3: a Python patch of `core.lua` sent through a heredoc turned the Lua escapes `\t`, `\r`, `\n` and `\\` into a real tab, newline and a lone backslash, which broke the file. The project's syntax check caught it immediately and the lines were repaired with the Edit tool. Scratch scripts written the same way failed the same way twice. A verification script that ran against the wrong repository in an earlier step also reported "0 mismatches" vacuously, which is the same family of silent-tooling faults.
- **Evidence:** `test\harness\syntax_check.lua` output for `core.lua` (unfinished string at the whitespace pattern); the repaired lines; the wrong-repository verification run and its re-run with explicit `git -C` paths.
- **Suggested:** CLAUDE.md (write any code or script containing backslashes with the Write or Edit tools, never through a shell heredoc; give every verification script an explicit repository path and make it fail loudly, never pass vacuously, when its input list is empty).
- **Triage:**

### LL-008 — The recorded state repeatedly lagged the real state (2026-09-29)

- **Area:** AI-behavior
- **What happened:** Several times during the session the ledger and `CLAUDE.md` fell behind what had actually happened. After the first push the ledger still named an older commit for the review folder; after Steps 1 and 2 were pushed it still said nothing beyond spikes was built, or that Step 2 had not started; the push policy text still said every push asks; `CLAUDE.md` still said "nothing is built"; and a ledger line Claude wrote to say local and remote were synchronized at a named commit was stale one commit later, because a line that names HEAD is always one commit behind the commit that edits it. The second reviewer found most of these, and each was corrected only after it was pointed out. The developer's retrospective named documentation discipline as the one thing Claude needs to improve.
- **Evidence:** the reconciliation commits `ce371f9`, `c656306` and `9089c74`; the second reviewer's stale-versus-historical review; the developer's retrospective (2026-09-29).
- **Suggested:** CLAUDE.md (in the same step as any commit, push, review-folder refresh or completed step, update the ledger and check it against `git log`, `git ls-remote` and the review folder's manifest; never record the hash of HEAD in the ledger; treat a stale ledger as a defect Claude should find, not one the reviewer finds).
- **Triage:**

### LL-009 — A safeguard grew far beyond its risk: hours spent on read isolation (2026-09-29)

- **Area:** process
- **What happened:** To let the second reviewer read the project safely, the developer and Claude built a review clone with three independently tested push locks, proposed branch protection on `main`, and then the developer spent about three and a half hours trying to confine the reviewer's tool to reading one folder. The read restriction turned out not to be enforceable, and a write restriction to the review folder, confirmed by write tests and a network control test, was enough for the real risk (damage to the development repository or GitHub). The developer's retrospective named this as overengineering. Claude contributed: it proposed and built the clone locks and the branch-protection ruleset before asking which capability the risk actually needed to be closed.
- **Evidence:** the DL-023 addenda (clone and locks, the plain review folder, the final tested state); the developer's retrospective (2026-09-29).
- **Suggested:** CLAUDE.md (before adding a safeguard, state in one sentence the loss it prevents and the cheapest control that prevents it; when a second or third control is proposed for the same risk, or one control has taken more than an hour, Claude says plainly that the design may be overengineered; the developer asked Claude to call this out directly).
- **Triage:**
