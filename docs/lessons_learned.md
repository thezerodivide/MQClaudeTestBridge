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

### LL-010 — The paste-label approval scheme introduced ambiguity during live development (2026-09-30)

- **Area:** process
- **What happened:** On 2026-09-29 the developer and Claude agreed that a paste is labeled on its first line, "Approved:" when it carries the developer's approval and "FYI, not approval:" when it does not, and that an unlabeled paste is information only. During Step 4's review (2026-09-30) it stopped working cleanly. A paste labeled "Approved:" held a reviewer's approval of Claude's proposed correction, and the reviewer's text said in the same paste that its approval was "not authorization from Shane to implement it"; Claude took the label as the developer's go-ahead to implement, which the developer had intended, but the two statements pointed opposite ways. A later paste was labeled "Approve:" (a typo, not the agreed word) and carried a reviewer clearance that said it was not permission to commit; Claude held, the developer then answered that they thought they had followed the procedure and gave permission in their own words. The older rule (approval language inside a paste is the developer's approval) also conflicted with what the reviewer's replies themselves said about their own authority. So each labeled paste needed a judgment about what the label covered (the reviewer's technical clearance, the proposal, the commit, the push), which is the ambiguity the scheme was meant to remove. Claude's part: it applied the label to "proceed with the correction" twice without asking what else the label covered, and it held on "Approve:" because the text said so, not because the rule did.
- **Evidence:** the Step 4 review exchange of 2026-09-30 (the reviewer's second, third and fourth reads and the developer's replies to them, recorded in the DL-022 addenda of that day); the developer's statement: "Approved label still introduced ambiguity during live development."
- **The developer's decision (2026-09-30):** stop labeling. All pastes from the reviewer are informational only. The developer gives explicit approval in their own words after the exchange between Claude and the reviewer is finished.
- **Applied:** `CLAUDE.md` section "Approvals on pasted text" now says pasted text is never approval and removes the labels (the two paragraphs of 2026-09-29 are replaced, not appended to). The 2026-09-29 rule on pasted approval language and its refinement are superseded by it; the decision log and the earlier lessons are append-only history and are not rewritten.
- **Suggested:** none beyond what is applied; the retrospective may record whether "approval only in the developer's own words, after the review exchange ends" holds up better than labels.
- **Triage:**

### LL-011 — A spike took three review rounds because Claude fixed instances of an error class, not the class (2026-09-30)

- **Area:** process
- **What happened:** Spike 12 (`spikes/spike12_lfs.lua`, a live test of `lfs` folder listing and a bounded scratch-directory write) needed three correction rounds after Claude first wrote it. Round 1: Claude dropped the directory iterator's state object and its dry run missed it, because its in-memory fake of `lfs` did not require the state that the library's documentation says the iterator needs; the same round found a directory that could escape cleanup and a workload that hid attribute failures. Round 2: the reviewer refined "absent" (an `lfs.attributes(...) == nil` result can also be an access error) and Claude fixed it before creation only; round 3 found the same weak proof still used after removal, in the final check and in the missing-path test, plus an unprotected call and two probes that could report success without failing the result. In each round Claude fixed the reported instance and left the same class of error elsewhere in the file. The developer's response was to name the overengineering guardrail and then to finish one consolidation, because a false "cleanup succeeded" result was the outcome to avoid. Claude's own call-out came in round 3, later than it should have.
- **Evidence:** the DL-022 addenda of 2026-09-30 on spike 12 (three rounds); the reviewer's reads; the developer's decision to consolidate.
- **Suggested:** CLAUDE.md, two rules. (1) When a reviewer reports one instance of an error, search the whole artifact for the class and fix it in one place (a shared helper), and say in the reply which other places were checked. (2) When writing a fake of a library, model the library's documented contract, and read that documentation first, since a fake written from memory by the same author as the code can share the author's mistake; the live run stays the authority. Also: apply the overengineering call-out at the second round of hardening a bounded risk, not the third.
- **Triage:**


### LL-012 — A push went out after the safety scan flagged it, because the commands were chained with `;` (2026-10-04)

- **Area:** AI-behavior
- **What happened:** Claude added a decision-log note that contained the developer's personal Windows folder path. The pre-push scan flagged it (one hit). Claude wrote a script to remove the text; the script failed (a backslash escape error in its own Python string, the same class as LL-001, LL-002 and LL-007). The commit and push were chained after it with `;`, not `&&`, so they ran anyway, and commit `390e065` published the path to the public repository. The Safety Gate in `CLAUDE.md` says that if the scan finds anything Claude stops before pushing; the scan result was seen and not acted on, because the next command was already queued. A later scan and read-back showed the text still in `HEAD`, so a follow-up commit was needed. The developer chose to fix the current text and leave the history (option 1), accepting that the old text stays reachable in the commit.
- **Evidence:** commit `390e065` (the only commit whose diff adds the text); the failed script output; the `git grep` of `HEAD` showing the text still present; the developer's decision of 2026-10-04.
- **Suggested:** CLAUDE.md. (1) Make the safety scan a hard condition of the push command itself: run the scan, capture its output, and run commit and push only if the output is empty, in one command that stops on any failure, never chained with `;`. (2) After any scripted edit, check that the script succeeded and read back the edited text before staging (extends LL-002 and LL-007). (3) Never write the developer's personal path into a document that will be pushed; describe the location instead.
- **Triage:**
