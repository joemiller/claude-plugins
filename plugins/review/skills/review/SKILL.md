---
description: "Multi-model code review with cross-validation"
allowed-tools: Bash(git:*), Bash(codex:*), Agent
---

# Run parallel code reviews with cross-validation.

## Overview

Dispatches two independent reviewers (Claude and
Codex) in parallel on the same code, then a judge
agent validates and deduplicates findings. You are
a pure dispatcher — you do not review code, edit
files, or inject your own opinions.

## Prerequisites

- `git` — all scope resolution uses git commands
- `codex` — optional; if unavailable, proceeds with
  Claude-only findings
- `review-focus:` in project CLAUDE.md — optional;
  if present, injected into reviewer prompts

## Instructions

### Step 1: Determine Scope

Parse `$ARGUMENTS`:
- Strip `--quick` flag if present; record as boolean.
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

Build a **scope brief**:

```
Repository: <REPO>
Branch: <BRANCH>
Scope: <human-readable description>
Files:
<file list, one per line>

Diff stat:
<git diff --stat output, if available>
```

### Step 2: Launch Parallel Reviews

Launch both reviews simultaneously.

**Claude:** Dispatch `subagent_type: "review:reviewer"`
with `mode: "bypassPermissions"`.

Prompt:
```
Review the code described below. Use git and file
reading tools to examine the changes and surrounding
context.

<SCOPE BRIEF>

<If review-focus configured:>
Project review focus (prioritize these): <FOCUS>
```

**Codex:** Dispatch an Agent subagent with
`mode: "bypassPermissions"` and
`allowed-tools: Bash(codex:*)` that runs:

```bash
codex exec -m gpt-5.4 \
  --config model_reasoning_effort="high" \
  --sandbox read-only \
  --full-auto \
  2>/tmp/codex-review-stderr.log <<'PROMPT'
Perform an adversarial code review. Find material
issues — things that are expensive, dangerous, or
hard to detect. Do NOT report style, naming, or
speculative concerns.

<SCOPE BRIEF>

<If review-focus configured:>
Project review focus (prioritize these): <FOCUS>

Use git and read files to examine the changes and
surrounding context.

Review focus categories:
- Trust boundaries
- Resource management
- Concurrency
- Input handling
- Error handling
- State corruption

For each finding, use this exact format:

    FINDING: <sequential id starting at 1>
    FILE: <path relative to repo root>
    LINES: <start>-<end>
    SEVERITY: <high|medium|low>
    CATEGORY: <trust-boundary|resource-leak|
               race-condition|input-validation|
               error-handling|state-corruption|other>
    ISSUE: <one-line summary>
    DETAIL: <explanation>
    RECOMMENDATION: <concrete fix>

If there are no material findings, return:
    NO_FINDINGS: Code review found no material issues.
PROMPT
```

### Step 3: Judge

Skip if `--quick` is set, or all reviewers that ran
returned `NO_FINDINGS`.

Dispatch `subagent_type: "review:judge"` with
`mode: "bypassPermissions"`.

Prompt:
```
Two independent models reviewed the same code.
Validate their findings against the actual code,
deduplicate, and produce a merged set of findings.

Use git and file reading tools to verify each
finding against the actual code.

<SCOPE BRIEF>

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

**Codex failure:** Read `/tmp/codex-review-stderr.log`
for the error. Include it as a `WARNING:` line in
the report header. The judge still runs on Claude's
findings alone.

**Empty scope:** Tell the user there is nothing to
review and stop. Do not launch any agents.

## Examples

Input: `/review:review`
(no args → reviews all uncommitted changes)

Input: `/review:review HEAD~3..HEAD`
(reviews last 3 commits)

Input: `/review:review --quick src/server.go`
(quick review of one file, no judge)
