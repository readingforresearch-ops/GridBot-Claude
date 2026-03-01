# GridBot Development Checklists & Prompts

> These checklists exist because of real bugs introduced during development.
> Claude should apply the relevant checklist automatically before any code change — without being asked.

---

## CHECKLIST A — Before ANY Code Change (Universal)

Apply this before touching any file.

```
[ ] Read the FULL function/section being modified — not just the target lines
[ ] Note every guard, edge case, and disable condition in the code being replaced
[ ] Grep ALL project files for old names/variables being changed — list every hit
[ ] Identify all affected files: Executor, Guardian, Planner, all .md docs
[ ] Check Save / Load / Clear / Publish for any new GV being added or removed
[ ] Trace ALL early return paths in OnTick that could bypass the new code
[ ] Validate new inputs against: 0 value, negative value, extreme values
[ ] List what documentation files need updating
Report this checklist BEFORE writing any code.
```

---

## CHECKLIST B — Replacing or Removing a Feature

Apply when removing an input, variable, GV, or block of logic.

```
[ ] Search ALL 3 bot files + all .md docs — list every reference found
[ ] For each reference: will it BREAK / need UPDATING / can be DELETED?
[ ] Identify what the old code was protecting against (guards, edge cases)
[ ] For removed variables: find every READ, WRITE, and CONDITIONAL that uses it
[ ] For removed GVs: confirm Save / Load / Clear / Publish all updated
[ ] After removal: grep again — confirm ZERO stale references remain
[ ] Update all docs that mention the removed feature
Do NOT start coding until the full impact list is confirmed.
```

---

## CHECKLIST C — Adding Something New

Apply when adding a new input, variable, GV, or feature block.

```
[ ] First ANALYZE — should this feature exist given the existing system?
[ ] What existing mechanism already handles this, partially or fully?
[ ] What are the failure modes if set to 0, negative, or an extreme value?
[ ] Which existing patterns in the codebase should this follow?
[ ] Will this need OnInit validation?
[ ] Which state functions need updating: Save / Load / Clear / Publish / Dashboard?
[ ] Which docs need updating?
Answer these questions first. Do NOT write code until the approach is approved.
```

---

## CHECKLIST D — Post-Implementation Self-Review (Mandatory)

Run after EVERY implementation before marking done.

```
[ ] Grep for ALL references to removed variables/inputs — confirm zero remaining
[ ] Check every state function: Save / Load / Clear / Publish — new GVs in all?
[ ] Check all early return paths — does new code get bypassed anywhere?
[ ] Check OnInit for validation of new inputs (0-value traps, range limits)
[ ] Check cross-file impact — Planner, Guardian, docs — anything still stale?
[ ] Compile check (mental): any undeclared variables, unused variables?
[ ] Dashboard display — does it need updating for new/removed state?
Report findings. Do not mark task done until all boxes checked.
```

---

## CHECKLIST E — Root Cause / Crash Analysis

Apply when analyzing a live failure, unexpected behavior, or crash.

```
[ ] Read the ACTUAL code for every mechanism being analyzed — do not assume behavior
[ ] Trace the exact tick-by-tick / event-by-event sequence of what happened
[ ] For each system that should have fired — why exactly did it NOT fire?
[ ] Distinguish: configuration error vs design flaw vs code bug
[ ] Check timing: which bot fires on tick level vs M5 level vs timer level?
[ ] Check GV state: what did each GV contain at the moment of failure?
[ ] Do NOT recommend a fix until root cause is confirmed from actual code
```

---

## CHECKLIST F — Feature Debate (Should This Exist?)

Apply when a user asks about a feature or when implementing feels wrong.

```
[ ] What does this feature actually DO that no other mechanism already does?
[ ] What is the cost of having it? (complexity, conflicts with other systems)
[ ] What is the cost of NOT having it? (what scenario requires it?)
[ ] Does it work WITH or AGAINST the grid's core recovery logic?
[ ] If removed, which existing mechanism covers the gap?
Answer all 5 before recommending keep or remove.
```

---

## Quick Reference — Which Checklist for Which Situation

| Situation | Checklist |
|---|---|
| Any code change | **A** (always) |
| Replacing an input/variable | **A + B** |
| Removing a feature entirely | **B** (most critical) |
| Adding something new | **A + C** |
| After any implementation | **D** (always) |
| Crash or unexpected behavior | **E** |
| "Should we do X?" question | **F** before any coding |
| Significant multi-file change | **A + B/C + D** |

---

## Known Bug Patterns From This Project

These specific bugs have occurred. Watch for them:

| Bug | Cause | Prevention |
|---|---|---|
| New input with `= 0` fires hard stop instantly | Old code had `> 0` disable guard — not preserved | Checklist A: note guards in code being replaced |
| Planner file still references old input names | Only grepped Executor, not all files | Checklist B: grep ALL files before renaming |
| New GV not deleted in ClearSystemState | Added to Save/Load but forgot Clear | Checklist C+D: trace all state functions |
| Peak equity set by floating spike, triggers on normal pullback | Used ACCOUNT_EQUITY instead of ACCOUNT_BALANCE | Checklist C: question why this specific value is correct |
| Feature built then immediately torn down | Implemented before analyzing whether it should exist | Checklist F: debate before coding |
| Early `return` path bypasses new safety code | Did not trace all OnTick return paths | Checklist A: trace all early returns |

---

## Instruction for Claude

> **Read this file at the start of any GridBot coding session.**
> Apply the relevant checklist(s) automatically — do not wait to be asked.
> When in doubt, run Checklist A + D on every change, no matter how small.
> The cost of the checklist is one minute. The cost of a missed bug is a live trading failure.
