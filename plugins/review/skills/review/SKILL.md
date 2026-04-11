---
description: "Multi-model code review with cross-validation"
allowed-tools: Bash(git:*), Bash(codex:*), Agent
---

# /review:review

Independent reviews from Claude and Codex,
cross-validated, merged into a single report.

## Input

Scope: $ARGUMENTS

Default (no arguments): all uncommitted changes
(`git diff HEAD`).

Accepted scope forms:
- File path: `src/server.zig`
- Multiple files: `src/server.zig src/client.zig`
- Git range: `HEAD~3..HEAD`
- Freeform: `last 2 commits`, `staged changes`

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

Gather repo info by running these git commands:
- `git rev-parse --show-toplevel` — extract the
  repo name from the last path component
- `git branch --show-current`

Resolve the scope to a **file list** and **diff stat**.
Pick the right git command based on scope type:

- Uncommitted changes: `git diff HEAD`
- Staged: `git diff --cached`
- Git range: `git diff <range>`
- File paths: skip diff, just use the paths
- No commits yet: `git ls-files`

Run `git diff --stat <scope>` to get the diff stat
summary. Run `git diff --name-only <scope>` to get
the file list. For file-path scope or no-commits
repos, the file list is the paths themselves and
there is no diff stat.

If both are empty, tell the user there is nothing
to review and stop.

Build a **scope brief** that will be passed to all
reviewers and validators:

```
Repository: <REPO>
Branch: <BRANCH>
Scope: <human-readable description, e.g. "uncommitted
       changes" or "HEAD~3..HEAD">
Files:
<file list, one per line>

Diff stat:
<git diff --stat output, if available>
```

Check for `review-focus:` in the project's CLAUDE.md.
If present, note it for injection into review prompts.

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
context.

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

The agent should return the codex output as-is.

If `codex exec` fails or is not available, read
`/tmp/codex-review-stderr.log` for the error reason.
Include the error in the warning, then proceed in
claude-only mode.

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
finding against the actual code.

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

Count findings from each source by reading the
structured output. For the judge's output, count
findings by STATUS and CONFIRMED_BY fields.

Render the report as:

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

If codex failed, add a `WARNING:` line after the
heading with the error from `/tmp/codex-review-stderr.log`.
Omit the `Codex findings:` count.

If `--quick`, append `[quick]` to the heading and
omit the Status column (there is no judge output).

If no findings survived, just display:
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
