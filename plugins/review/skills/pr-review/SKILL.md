---
description: "Multi-model PR code review with cross-validation"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(codex:*), Bash(mktemp:*), Bash(rm:*), Agent
---

# Review a GitHub pull request with parallel reviewers and cross-validation.

## Overview

Clones a PR to a temp directory, dispatches two
independent reviewers (Claude and Codex) in parallel,
then a judge agent validates and deduplicates
findings. Always clones fresh — never checks out
branches in the user's working tree. You are a pure
dispatcher — you do not review code, edit files, or
inject your own opinions.

## Prerequisites

- `gh` — used for PR metadata, cloning, and checkout
- `git` — diff computation and scope resolution
- `codex` — optional; if unavailable, proceeds with
  Claude-only findings
- `review-focus:` in the cloned repo's CLAUDE.md —
  optional; if present, injected into reviewer prompts

## Instructions

### Step 1: Setup and Scope

Parse `$ARGUMENTS`:
- Strip `--quick` flag if present; record as boolean.
- Remaining text must be a GitHub PR URL. If not,
  tell the user and stop.

Extract PR metadata:

```
gh pr view <URL> --json number,title,body,baseRefName,headRefName,headRepository,headRepositoryOwner
```

Clone to a temp directory:

```
mktemp -d /tmp/pr-review-XXXXXX
gh repo clone <owner>/<repo> <temp-dir>/<repo> -- --depth=50
```

Checkout the PR:

```
git -C <temp-dir>/<repo> fetch origin pull/<number>/head:pr-<number> && \
git -C <temp-dir>/<repo> checkout pr-<number>
```

Compute the diff. If the base branch is missing from
the shallow clone, fetch it first:

```
git -C <temp-dir>/<repo> fetch origin <base> --depth=50
git -C <temp-dir>/<repo> diff origin/<base>...HEAD --stat
git -C <temp-dir>/<repo> diff origin/<base>...HEAD --name-only
```

Build the **scope brief**:

```
Repository: <owner>/<repo>
Branch: <head-branch> (PR #<number>)
PR title: <title>
Working directory: <temp-dir>/<repo>
Diff range: origin/<base>...HEAD
Files:
<file list, one per line>

Diff stat:
<git diff --stat output>

PR description:
<body, truncated to 500 chars if non-empty>
```

### Step 2: Launch Parallel Reviews

Launch both reviews simultaneously.

**Claude:** Dispatch `subagent_type: "review:reviewer"`
with `mode: "bypassPermissions"`.

Prompt:
```
Review the code described below. Use git and file
reading tools to examine the changes and surrounding
context. The repo is cloned at the working directory
shown below — use absolute paths for all file reads
and git -C for all git commands.

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
  -C <temp-dir>/<repo> \
  2>/tmp/codex-review-stderr.log <<'PROMPT'
Perform an adversarial code review. Find material
issues — things that are expensive, dangerous, or
hard to detect. Do NOT report style, naming, or
speculative concerns.

<SCOPE BRIEF>

<If review-focus configured:>
Project review focus (prioritize these): <FOCUS>

Use git and read files to examine the changes and
surrounding context. The diff range is
origin/<base>...HEAD.

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
finding against the actual code. The repo is cloned
at the working directory shown below — use absolute
paths for all file reads and git -C for all git
commands.

<SCOPE BRIEF>

--- Claude findings ---

<CLAUDE FINDINGS>

--- Codex findings ---

<CODEX FINDINGS>
```

The judge returns structured FINDING blocks, not
formatted markdown.

### Step 4: Cleanup

Remove the temp directory:

```
rm -rf <temp-dir>
```

## Output Format

You are responsible for ALL formatting. Agents
return structured text (FINDING / FILE / LINES /
etc. blocks). Parse these and render markdown.

Strip the temp directory prefix from all file paths —
render paths relative to the repo root.

Filter out low severity and disputed findings. Only
present high and medium severity.

    ## Review: <owner>/<repo> PR #<number> (<head-branch>)

    **<PR title>**

    Scope: origin/<base>...<head-branch>
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
- Codex failed: add `WARNING:` line after title,
  omit `Codex findings:` count
- No findings: display `No material issues found.`

## Error Handling

**Codex failure:** Read `/tmp/codex-review-stderr.log`
for the error. Include it as a `WARNING:` line in
the report header. The judge still runs on Claude's
findings alone.

**Invalid input:** If the argument is not a GitHub
PR URL, tell the user and stop. Do not launch agents.

**Shallow clone missing base:** Fetch the base branch
with `--depth=50` and retry the diff.

**Cleanup on failure:** Always remove the temp
directory, even if the review pipeline fails.

## Examples

Input: `/review:pr-review https://github.com/org/repo/pull/42`

Input: `/review:pr-review --quick https://github.com/org/repo/pull/42`
(skip judge, return raw union of findings)
