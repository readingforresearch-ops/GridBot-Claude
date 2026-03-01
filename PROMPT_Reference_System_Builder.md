# Reusable Prompt: Persistent Reference System Builder
# Copy-paste the prompt below into any new Claude Code session

---

## THE PROMPT (copy everything below this line)

---

I want you to create a comprehensive, persistent reference system for this project that enables you to maintain full context across all future sessions.

**GOAL:** Build a knowledge base so complete that in any future session, you can read a few files and immediately understand the entire project without re-analyzing the codebase.

---

### PHASE 1: DEEP PROJECT ANALYSIS

Before creating anything, perform a thorough analysis:

1. **Project Structure Scan**
   - Map every file and directory
   - Identify languages, frameworks, dependencies
   - Note file sizes and modification dates
   - Identify entry points, configs, tests, docs

2. **Code Deep Dive**
   - Extract ALL functions/methods with file:line locations
   - Extract ALL input parameters, configs, environment variables
   - Extract ALL global state, shared variables, singletons
   - Identify data types, interfaces, structs, enums, models
   - Map execution flows (startup, main loop, shutdown, error handling)
   - Find hardcoded constants and magic numbers

3. **Architecture Analysis**
   - How do components/modules communicate?
   - What protocols are used (API, events, shared state, messaging)?
   - What are the rate limiters, throttles, cooldowns?
   - What safety checks, guards, and validations exist?
   - What persists across restarts vs. what is recalculated?

4. **Documentation Catalog**
   - What docs already exist?
   - What gaps exist in documentation?
   - Are there any known bugs, TODOs, or technical debt?

---

### PHASE 2: CREATE REFERENCE FILES

Create these files in the Claude Code memory directory:

#### File 1: `MEMORY.md` (auto-loaded every session, keep under 200 lines)

Structure it as:

```markdown
# [Project Name] Memory

## Reference System Index
> **Start here every session.** Load specific ref files as needed.

| File | Contents | When to Load |
|---|---|---|
| `MEMORY.md` (this file) | Overview, quick lookup | Always (auto-loaded) |
| `REF_CODEBASE_MAP.md` | Functions, params, globals, types, flows | Modifying code, debugging |
| `REF_ARCHITECTURE.md` | Communication, safety, patterns, fixes | Debugging, investigating |

## Quick Lookup
(10 most common questions with instant answers)

## System Overview
(2-3 sentence project description)

## Key Files
(List main source files with one-line descriptions)

## Critical Rules
(Things that MUST NOT be forgotten — coupling, constraints, gotchas)

## Key Behaviors
(Core business logic in bullet points)

## Bug Fix Summary
(One-liners with references to detail file)

## Documentation Index
(List all docs with locations)
```

#### File 2: `REF_CODEBASE_MAP.md` (loaded on demand, no line limit)

Structure it as:

```markdown
# REF_CODEBASE_MAP.md — Code Registry

## Section 0: File Inventory
(Every source file with line count and purpose)

## Section 1: Function Registry
(Every function with file:line, parameters, return type, purpose — grouped by file)

## Section 2: Input Parameters / Configuration
(Every configurable value with type, default, valid range, file:line)

## Section 3: Global Variables / Shared State
(Every global with type, purpose, who reads/writes, persistence status)

## Section 4: Data Types
(Structs, enums, interfaces, models with fields and file:line)

## Section 5: Execution Flows
(Step-by-step traces of key paths: init, main loop, shutdown, error)

## Section 6: Constants & Magic Numbers
(Every hardcoded value with location and meaning)
```

#### File 3: `REF_ARCHITECTURE.md` (loaded on demand, no line limit)

Structure it as:

```markdown
# REF_ARCHITECTURE.md — Architecture, Safety & History

## Section 1: Communication Protocol
(How components talk — APIs, events, shared state — with file:line for publishers AND readers)

## Section 2: Rate Limiters & Throttles
(Every cooldown, debounce, rate gate with interval and location)

## Section 3: Safety Check Inventory
(Every guard, validation, assertion — init-time AND runtime)

## Section 4: Bug Fix History
(Every fix with ID, description, root cause, fix location — chronological)

## Section 5: Coding Conventions & Patterns
(Naming conventions, common patterns, architectural rules)

## Section 6: State Persistence Map
(What survives restart vs. what is recalculated — with restore mechanisms)

## Section 7: Critical Cross-References
(Multi-step protocols that span components — step-by-step with file:line)
```

---

### PHASE 3: QUALITY REQUIREMENTS

- **Every function, variable, and check MUST have file:line references** — no vague descriptions
- **Use tables** for scannable data (not prose paragraphs)
- **Group by file/module** for easy navigation
- **MEMORY.md must stay under 200 lines** — it's auto-loaded every session, keep it lean
- **REF files have no line limit** — be thorough, not brief
- **Include both publisher AND reader** locations for any shared state
- **Adapt the template** to fit this project — add/remove sections as appropriate

---

### EXECUTION

**NOTE: Give me a step-by-step plan first. When I approve, then implement.**

Analyze the codebase thoroughly, design the reference system structure tailored to this specific project, present the plan, and only build it after my approval.
