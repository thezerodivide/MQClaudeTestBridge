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
