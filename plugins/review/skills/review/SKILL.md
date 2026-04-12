---
description: "Multi-model code review with cross-validation"
allowed-tools: Bash(git:*), Bash(codex:*), Bash(shuf:*), Agent
---

# Run parallel code reviews with cross-validation.

## Overview

Dispatches N Claude + N Codex reviewers in parallel,
each examining files in a different random order to
broaden coverage. A judge agent then validates and
deduplicates all findings. You are a pure dispatcher —
you do not review code, edit files, or inject your
own opinions.

## Prerequisites

- `git` — all scope resolution uses git commands
- `shuf` — randomizes file ordering per agent (coreutils)
- `codex` — optional; if unavailable, proceeds with
  Claude-only findings
- `review-focus:` in project CLAUDE.md — optional;
  if present, injected into reviewer prompts

## Instructions

### Step 1: Determine Scope

Parse `$ARGUMENTS`:
- Strip `--quick` flag if present; record as boolean.
- Strip `--agents N` flag if present; record N
  (minimum 1, maximum 10).
- If `--agents` is not specified, ask the user using
  the AskUserQuestion tool: "How many review agents?"
  with options: "1 (Recommended)" (standard 1+1
  review) and "3" (broader coverage, 3+3 agents).
- If N is not a positive integer, show usage and stop.
  Clamp values outside 1–10 to the nearest bound and
  warn.
- Remaining text is the scope. If empty, use
  `git diff HEAD`.

Translate freeform scope to git commands:
- `last N commits` → `HEAD~N..HEAD`
- `staged` / `staged changes` → `--cached`
- File paths → use as-is
- Git ranges → use as-is

Gather repo info:
- `git rev-parse --show-toplevel` — extract the
  repo name from the last path component
- `git branch --show-current`

Resolve the scope to a **file list** and **diff stat**:
- Uncommitted changes: `git diff HEAD`
- Staged: `git diff --cached`
- Git range: `git diff <range>`
- File paths: skip diff, just use the paths
- No commits yet: `git ls-files`

Run `git diff --stat <scope>` and
`git diff --name-only <scope>`. For file-path scope
or no-commits repos, the file list is the paths
themselves and there is no diff stat.

If both are empty, tell the user there is nothing
to review and stop.

Build a **base scope brief** (unshuffled, used by
the judge):

```
Repository: <REPO>
Branch: <BRANCH>
Scope: <human-readable description>
Files:
<file list, one per line>

Diff stat:
<git diff --stat output, if available>
```

### Step 2: Generate Randomized Scope Briefs

For each of the 2N agents (N Claude + N Codex),
generate a scope brief with files in a different
random order. Run a fresh `shuf` for each agent —
do NOT reuse a previous shuffle.

**Get a shuffled file list** (one Bash call per agent):

```bash
git diff --name-only <scope> | shuf
```

Read the output — this is the shuffled file list for
this agent. All commands start with `git` to avoid
permission prompts.

**Build the agent's scope brief:**

```
Repository: <REPO>
Branch: <BRANCH>
Scope: <human-readable description>
Files:
1. <first shuffled file>
2. <second shuffled file>
3. <third shuffled file>
...
```

The numbered list naturally guides the agent to
process files in the given order. Do NOT include
any mention of shuffling, randomization, or that
other reviewers exist.

### Step 3: Launch Parallel Reviews

Launch all 2N reviews simultaneously in one parallel
batch — N Claude agent dispatches + N Codex bash
commands.

Build a **review prompt** for each agent using the
template below (substituting that agent's shuffled
scope brief). This is the single source of truth
for what both Claude and Codex reviewers receive:

```
Perform an adversarial code review. Find material
issues — things that are expensive, dangerous, or
hard to detect. Do NOT report style, naming, or
speculative concerns.

<AGENT i's SHUFFLED SCOPE BRIEF>

<If review-focus configured:>
Project review focus (prioritize these): <FOCUS>

Use git and read files to examine the changes and
surrounding context.

Review focus categories (prioritize failures that
are expensive, dangerous, or hard to detect):

- Trust boundaries: auth, permissions, tenant
  isolation, input from untrusted sources
- Resource management: leaks, cleanup failures,
  missing errdefer/finally/close
- Concurrency: race conditions, ordering assumptions,
  stale state, re-entrancy
- Input handling: unbounded values, missing
  validation, injection, path traversal
- Error handling: swallowed errors, silent failures,
  partial failure states
- State corruption: invariant violations, unreachable
  states, irreversible damage

Evidence standard: Every finding must be defensible
from the code you can see. Do not invent files,
lines, code paths, or failure scenarios you cannot
support. If a conclusion depends on an inference,
state that in the DETAIL field and set SEVERITY
accordingly. Prefer one strong finding over several
weak ones. If the code looks correct, say so and
return no findings.

For each finding, use this exact format:

    FINDING: <sequential id starting at 1>
    FILE: <path relative to repo root>
    LINES: <start>-<end>
    SEVERITY: <high|medium|low>
    CATEGORY: <trust-boundary|resource-leak|
               race-condition|input-validation|
               error-handling|state-corruption|other>
    ISSUE: <one-line summary>
    DETAIL: <explanation — as long as needed>
    RECOMMENDATION: <concrete fix>

If there are no material findings, return:
    NO_FINDINGS: Code review found no material issues.
```

**Claude (N instances):** For each instance i (1..N),
dispatch `subagent_type: "review:reviewer"` with
`mode: "bypassPermissions"`. Pass the review prompt
as the agent's prompt.

**Codex (N instances):** For each instance i (1..N),
run `codex exec` directly via Bash (the orchestrator
has `Bash(codex:*)` permission — do NOT delegate to
a subagent). Pass the review prompt as the heredoc:

```bash
codex exec -m gpt-5.4 \
  --config model_reasoning_effort="high" \
  --sandbox read-only \
  --full-auto \
  2>/tmp/codex-review-stderr-<i>.log <<'PROMPT'
<REVIEW PROMPT>
PROMPT
```

### Step 4: Collect and Merge Findings

Wait for all agents to complete. Record which
succeeded and which failed.

Concatenate findings by model type:

```
--- Claude reviewer 1 ---
<findings from Claude agent 1>

--- Claude reviewer 2 ---
<findings from Claude agent 2>

...

--- Codex reviewer 1 ---
<findings from Codex agent 1>

--- Codex reviewer 2 ---
<findings from Codex agent 2>

...
```

Count total Claude findings and total Codex findings
across all instances.

### Step 5: Judge

Skip if `--quick` is set, or all reviewers that ran
returned `NO_FINDINGS`.

Dispatch `subagent_type: "review:judge"` with
`mode: "bypassPermissions"`.

**When N > 1**, use this prompt:
```
Multiple independent reviewers reviewed the same
code (<N> Claude reviewers + <N> Codex reviewers).
Validate their findings against the actual code,
deduplicate, and produce a merged set of findings.

Expect significantly more duplicate findings than a
standard 2-reviewer run. Apply the same dedup rules:
same FILE with overlapping LINES describing the same
failure mechanism = merge.

Use git and file reading tools to verify each
finding against the actual code.

<BASE SCOPE BRIEF (unshuffled)>

--- Claude findings ---

<ALL CLAUDE FINDINGS>

--- Codex findings ---

<ALL CODEX FINDINGS>
```

**When N = 1**, use this prompt:
```
Two independent models reviewed the same code.
Validate their findings against the actual code,
deduplicate, and produce a merged set of findings.

Use git and file reading tools to verify each
finding against the actual code.

<BASE SCOPE BRIEF (unshuffled)>

--- Claude findings ---

<CLAUDE FINDINGS>

--- Codex findings ---

<CODEX FINDINGS>
```

The judge returns structured FINDING blocks, not
formatted markdown.

## Output Format

You are responsible for ALL formatting. Agents
return structured text (FINDING / FILE / LINES /
etc. blocks). Parse these and render markdown.

    ## Review: <REPO> (<BRANCH>)

    Scope: <scope description>
    <If N > 1:>
    Agents: <N> Claude + <N> Codex (<2N> total)
    Claude findings: <n> | Codex findings: <n>

    | # | Sev | File | Issue | Status |
    |---|-----|------|-------|--------|
    | 1 | high | path/file.go:42-58 | Issue summary | ✓ both |
    | 2 | med  | path/other.go:10 | Issue summary | ✓ claude |

    #### #1 [high] trust-boundary — Issue summary
    path/file.go:42-58

    Detail paragraphs from the finding.

    **Fix:** Recommendation from the finding.

    *Confirmed by both reviewers*

**Status column** (from judge's STATUS/CONFIRMED_BY):
- confirmed + both → `✓ both`
- confirmed + claude → `✓ claude`
- confirmed + codex → `✓ codex`
- disputed → `✗ disputed`
- uncertain → `? uncertain`

**Severity column:** high, med, low.

**Status line** (italics, after each finding):
- *Confirmed by both reviewers*
- *Found by claude, confirmed by judge*
- *Found by codex, confirmed by judge*
- *Disputed: reason*
- *Uncertain: reason*

**Variations:**
- `--quick`: append `[quick]` to heading, omit
  Status column (no judge ran)
- Codex failed: add `WARNING:` line after heading,
  omit `Codex findings:` count
- No findings: display `No material issues found.`

## Error Handling

**Partial Codex failure:** Read each
`/tmp/codex-review-stderr-<i>.log` for errors.
When N > 1, add `WARNING: <k> of <N> Codex agents
failed` after the heading. When N = 1, include the
error as a single `WARNING:` line. The judge still
runs on all collected findings.

**Partial Claude failure:** Same approach — count
failures, add `WARNING: <k> of <N> Claude agents
failed` after the heading, proceed with collected
findings.

**All Codex agents fail:** Add `WARNING:` line after
heading, omit `Codex findings:` count. The judge
runs on Claude findings alone.

**All agents fail:** Tell the user the review could
not be completed. Show error details.

**Empty scope:** Tell the user there is nothing to
review and stop. Do not launch any agents.

**Invalid `--agents`:** If the value is not a
positive integer, show usage and stop. Clamp values
outside 1–10 to the nearest bound and warn.

## Examples

Input: `/review:review`
(asks user for agent count, reviews uncommitted changes)

Input: `/review:review --agents 1`
(standard 1+1 review, all uncommitted changes)

Input: `/review:review --agents 3 HEAD~3..HEAD`
(3 Claude + 3 Codex agents, reviews last 3 commits)

Input: `/review:review --quick --agents 2`
(2+2 agents, no judge, reviews uncommitted changes)

Input: `/review:review --quick src/server.go`
(asks user for agent count, quick review of one file)
