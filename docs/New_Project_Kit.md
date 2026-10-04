# New Project Kit: the documents this method needs

How to start a new project with the same method this one (and PTAutoRoute before it) uses. The method is a set of documents that carry the rules and the state, so that a cold-start Claude session and a second reviewer can rebuild context from the repository alone, with nothing resting on anyone's memory. Written 2026-10-04 from a review of every document in this repository. This is a guide, not part of the Protocol; it changes no rule.

## The method in one paragraph

The spec says what the system must do. The decision log says why each material decision was made, append-only, in a fixed four-block shape. The ledger says what is true now, in four categories, updated in place. The Development Protocol and `CLAUDE.md` say how decisions are made and recorded. The developer facilitates and makes every decision and risk call; Claude drives the requirements conversation and surfaces what is verified, reasoned or unknown; an optional second reviewer (another AI) reviews and recommends but never decides. Work goes one change at a time, test-first, with tests that cite their source and are proven able to fail, and nothing is called ready beyond its evidence tier.

## The documents, in the order a new project needs them

| # | Document | Job | Carry over how | Update rule |
| --- | --- | --- | --- | --- |
| 1 | `docs/Development_Protocol.txt` | The process contract (22 sections). | Copy; then swap the few runtime-specific spots listed below. | Changed only by the developer, at a retrospective. |
| 2 | `CLAUDE.md` | The working agreement loaded every session: a summary of the Protocol's core rules, plus the rules about the reviewer, handoff headers, commits and pushes. | Copy the portable sections (table below); rewrite the project-specific ones. | In step with the code and the ledger (Protocol §18). |
| 3 | `SPEC.md` | What the system must do; authoritative. Confirmed facts, requirements, non-goals, roadmap with checkable phase gates, risks and spikes. | Write new. Keep the habit of dated `[CLARIFIED]` or `[CORRECTED]` markers for any in-place change. | In place, never silently; re-read end to end before release or handoff (§18). |
| 4 | `docs/decision_log.md` | Why each material decision was made. Starts with an "Active overrides index" so a supersession is visible where the log is read. | New file with the header, the index and the entry shape below. Seed it with a retrofit entry if a spec exists first. | Append-only; a correction is a dated addendum. |
| 5 | `docs/project_ledger.md` | Current state. Four categories (Resolved behavior, Confirmed live/system facts, Open implementation details, Out of scope), plus an "Up next" section that opens with a cold-start block, plus Dependencies and Pending Live Verification. | New file with these sections. | In place, with the correction visible; updated in the same step as any commit, push, review refresh or finished step. Never write the hash of HEAD in it. |
| 6 | `docs/User_Story_Template.md` | How new work starts: story, observation, facts, constraints, risk, success criteria; Claude's one-question-at-a-time conversation and the Requirement / Assumption / Open labels. | Copy; replace the few MacroQuest-specific lines. | Rarely. |
| 7 | `docs/lessons_learned.md` | Running log of lessons for a release retrospective; Triage left blank until then. | New file with the header and the how-it-works notes. | Append-only; annotate, never delete. |
| 8 | `docs/New_Project_Kit.md` (this file) | The checklist for the next project. | Copy and keep current. | When any of the above changes shape. |

Not documents but part of the method, outside or beside the repository:

- **A test harness and one check command** (here `test\check.cmd`: syntax check, then the tests of each language; exit 0 only if all pass), a rule that every test cites its source, and a mutation runner for logic-heavy code (Protocol §7). Here the runner is `mutate.py` (Lua) and a Python variant, kept outside the repository (see gaps).
- **A review folder for the second reviewer**, if one is used: a plain folder beside the checkout with no `.git`, a `MANIFEST.txt` (commit, hashes, which files are candidates), a `candidate/` subfolder for uncommitted files, and a refresh script (`refresh_review.py`, currently in Claude's memory folder, not the repository). The exact-artifact handoff in `CLAUDE.md` depends on it.
- **Claude's per-project memory notes** (`MEMORY.md` and its notes): reviewer role and alert rule, the routing line, the dependency policy, tooling quirks. These are per user and per machine, so a new project must not rely on them: every rule that matters is also in `CLAUDE.md`, and a new project should put it there.
- **`.gitignore`** for machine-specific config, generated folders and caches, and a tracked `config.example.toml` (or equivalent) for the machine-specific file.

## What in `CLAUDE.md` is portable

| `CLAUDE.md` section | Portable? |
| --- | --- |
| Authoritative documents | Rewrite the list for the new project; keep the one-line job of each document. |
| What this is | Project-specific. |
| Development Protocol: core rules | Portable as written (it summarizes the Protocol). |
| Working agreement: the developer facilitates, Claude surfaces | Portable. The date and the reason are this project's history; keep or replace. |
| Format of the second reviewer's replies (the two sections, the refinement rule, the alert rule, the routing line) | Portable if a second reviewer is used; drop it otherwise. |
| Handoff header on every reply | Portable. |
| Safety-sensitive code: the reviewer sees the final code | Portable; the example (an FFI crash risk) is this project's. |
| Pre-commit review handoff | Portable if a review folder is used. Replace the folder's name. |
| Approvals on pasted text | Portable. |
| Working agreements from the retrospective | Portable. |
| Commits and pushes, and the repository durability policy | Portable if the repository is public and has a remote; the policy is a pair of gates (authorization, safety scan) evaluated over the whole unpushed range. |
| Related projects (Protocol §21) | Project-specific. Start a list for the new platform. |
| Architecture, Testing | Project-specific. |

## Swap list in the Protocol and the story template

The Protocol was written for MacroQuest projects. The method does not depend on these; replace them:

- §8: the `macroquest\logs\<luaname>\` and `macroquest\config\<luaname>\` file schema.
- §4, §14, §16, §20: the examples and runtime names (MacroQuest, Project Triune, TAC, TLO, the door and canary examples).
- §21: "same platform/runtime" wording is generic, but the list lives in `CLAUDE.md`.
- `User_Story_Template.md`: "MacroQuest source in `references/`", game-rule examples, and the commit and push wording (the template points to `CLAUDE.md` for permissions).

## Bootstrap order for a new project

1. Create the repository with `.gitignore` and the Protocol (swap list applied).
2. Write `CLAUDE.md` from the portable sections, with an empty "Related projects" list and a one-paragraph "What this is".
3. Create the empty `decision_log.md` (header, overrides index, entry shape), `project_ledger.md` (four categories, an "Up next" cold-start block), `lessons_learned.md`, and copy `User_Story_Template.md`.
4. Run the first story through the template: the developer's story, Claude's restatement, one question at a time, labelled items, acceptance criteria approved before any solution. Record it in the decision log as DL-001 in the four-block shape, and write `SPEC.md` from what was approved.
5. Add the test harness and the single check command before the first code; write each test from a requirement with its source cited.
6. If using a second reviewer, create the review folder and manifest before the first review.
7. End each working day at a fixed cadence with the ledger's cold-start block current (Protocol §22).

## Gaps found by this review (not fixed; each needs a decision)

- **The helper scripts are not in the repository.** `mutate.py`, a Python mutation runner and `refresh_review.py` live in Claude's memory folder and a scratchpad, so a new project (or a new machine) would not have them. Moving them into the repository is a code commit and needs the developer's permission; `refresh_review.py` also hard-codes this project's paths.
- **No README.** The repository is public and has none; whether it needs one is the developer's call.
- **No template files.** The entry shape and the ledger's sections are described in prose (here, in the Protocol and in the story template), not as blank files to copy.
- **`CLAUDE.md` mixes portable and project-specific text** in one file; the table above is the only separation. Splitting it (a portable working agreement plus a short project file) would be a restructuring decision.
- **The Protocol is MacroQuest-flavoured** (swap list above). It is the developer's document and was not edited.
