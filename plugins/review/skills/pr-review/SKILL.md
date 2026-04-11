---
description: "Multi-model PR code review with cross-validation"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(codex:*), Bash(mktemp:*), Bash(rm:*), Agent
---

# /pr-review:pr-review

Independent reviews from Claude and Codex on a
GitHub pull request, cross-validated, merged into
a single report.

## Input

PR: $ARGUMENTS

Required: a GitHub PR URL.
Example: `https://github.com/owner/repo/pull/123`

Flags:
- `--quick` — skip cross-validation, return the
  union of both reviews

## The Rule

You are a PURE DISPATCHER. You do not review code.
You launch agents, collect output, and format results.
Do not edit source files. Do not fix issues. Do not
inject your own review opinions into the output.

---

## Pipeline

### Step 1: Setup and Scope

Parse `$ARGUMENTS`:
- Strip `--quick` flag if present; record as boolean.
- Remaining text must be a GitHub PR URL. If not,
  tell the user and stop.

Extract PR metadata:

```
gh pr view <URL> --json number,title,body,baseRefName,headRefName,headRepository,headRepositoryOwner
```

From the JSON response extract:
- PR number, title, body (description)
- Base branch name and head branch name
- Repository clone URL (construct from
  headRepositoryOwner and headRepository)

Clone to a temp directory:

```
mktemp -d /tmp/pr-review-XXXXXX
```

```
gh repo clone <owner>/<repo> <temp-dir>/<repo> -- --depth=50
```

Use `--depth=50` to keep the clone fast while
having enough history for the diff. If the PR has
more than 50 commits this is still fine — the diff
range will work with the available history.

Checkout the PR:

```
git -C <temp-dir>/<repo> fetch origin pull/<number>/head:pr-<number> && \
git -C <temp-dir>/<repo> checkout pr-<number>
```

Compute the diff range. The base branch is from
the PR metadata. Use:

```
git -C <temp-dir>/<repo> diff origin/<base>...HEAD --stat
git -C <temp-dir>/<repo> diff origin/<base>...HEAD --name-only
```

If either fails (e.g., shallow clone missing the
base), fetch the base and retry:

```
git -C <temp-dir>/<repo> fetch origin <base> --depth=50
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
```

If the PR body is non-empty, include it:

```
PR description:
<body, truncated to 500 chars if longer>
```

Check for `review-focus:` in a CLAUDE.md at the
repo root inside the clone. If present, note it
for injection into review prompts.

### Step 2: Launch Parallel Reviews

Launch both reviews simultaneously. Do not wait for
one before starting the other.

#### Claude Review

Dispatch the plugin's reviewer agent
(`subagent_type: "review:reviewer"`) with
`mode: "bypassPermissions"`.

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

The agent's system prompt already contains the review
focus categories, evidence standard, and output
schema. Pass only the scope brief and any
project-specific focus. The agent will read the
actual code itself.

#### Codex Review

Dispatch an Agent subagent with
`mode: "bypassPermissions"` and
`allowed-tools: Bash(codex:*)` that runs a single
Bash call:

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

The agent should return the codex output as-is.

If `codex exec` fails or is not available:
1. Read the file `/tmp/codex-review-stderr.log`
   using the Read tool
2. Include the error content in the final report
   header as a warning line
3. Proceed without codex findings — the judge still
   runs on Claude's findings alone

### Step 3: Judge

Skip this step if ANY of:
- `--quick` flag is set
- Both reviewers returned `NO_FINDINGS`
- Only one reviewer ran AND it returned `NO_FINDINGS`

Dispatch the plugin's judge agent
(`subagent_type: "review:judge"`) with
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

The judge agent's system prompt contains the
validation rules, dedup logic, and output schema.
Pass only the scope brief and both sets of findings.
The judge returns structured FINDING blocks, not
formatted markdown.

### Step 4: Format and Present

You are responsible for ALL formatting. The reviewer
and judge agents return structured text (FINDING /
FILE / LINES / etc. blocks). You parse these and
render the final markdown report.

Filter out low severity findings — only present high
and medium. Also filter out disputed findings. This
keeps PR reviews focused on what matters for the
merge decision.

In the rendered output, FILE paths should be
**relative to the repo root**, not absolute paths.
Strip the temp directory prefix.

Count findings from each source by reading the
structured output. Counts should reflect post-filter
totals. For the judge's output, count findings by
STATUS and CONFIRMED_BY fields.

Render the report as:

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

If codex failed, add a `WARNING:` line after the
title with the error from `/tmp/codex-review-stderr.log`.
Omit the `Codex findings:` count.

If `--quick`, append `[quick]` to the heading and
omit the Status column (there is no judge output).

If no findings survived filtering, just display:
`No material issues found.`

Status column mapping from judge's structured output:
- STATUS=confirmed, CONFIRMED_BY=both → `✓ both`
- STATUS=confirmed, CONFIRMED_BY=claude → `✓ claude`
- STATUS=confirmed, CONFIRMED_BY=codex → `✓ codex`
- STATUS=disputed → `✗ disputed`
- STATUS=uncertain → `? uncertain`

Severity column: high, med, low.

Status line in italics after each finding:
- `*Confirmed by both reviewers*`
- `*Found by claude, confirmed by judge*`
- `*Found by codex, confirmed by judge*`
- `*Disputed: <reason from DETAIL>*`
- `*Uncertain: <reason from DETAIL>*`

### Step 5: Cleanup

After presenting results, remove the temp directory:

```
rm -rf <temp-dir>
```
