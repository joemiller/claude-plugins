---
description: "Multi-model code review with cross-validation"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(mkdir:/tmp/review-skill), Bash(mktemp:*), Bash(rm:/tmp/review-skill/review-*), Write(/tmp/review-skill/*), Agent
---

# Run parallel code reviews with cross-validation.

## Overview

Dispatches N Claude + N Codex reviewers in parallel,
each examining files in a different random order to
broaden coverage. A judge agent then validates and
deduplicates all findings. Works on local changes
(uncommitted, staged, ranges, file paths) or a
GitHub PR URL. You are a pure dispatcher — you do
not review code, edit files, or inject your own
opinions.

PR mode clones to a temp directory and always cleans
up, even on failure. It never checks out branches in
the user's working tree.

## Prerequisites

- `git` — all scope resolution uses git commands
- `shuf` — randomizes file ordering per agent
  (coreutils, used by shuffle-diff.sh)
- `jq` — JSON processing (used by setup-pr.sh)
- `codex` — optional; if unavailable, proceeds with
  Claude-only findings
- `gh` — required for PR mode only (metadata, clone)

## Instructions

### Step 1: Determine Mode and Scope

Parse `$ARGUMENTS`:
- Strip `--agents N` flag if present; record N
  (minimum 1, maximum 10).
- If `--agents` is not specified, ask the user using
  the AskUserQuestion tool: "How many review agents?"
  with options: "1 (Recommended)" (standard 1+1
  review) and "3" (broader coverage, 3+3 agents).
- If N is not a positive integer, show usage and stop.
  Clamp values outside 1–10 to the nearest bound and
  warn.

**Detect mode:** If the remaining text contains a
GitHub PR URL, this is **PR mode**. Otherwise it is
**local mode** (remaining text is the scope; if
empty, default to `git diff HEAD`).

Create a temp directory (used by both modes):

```
mkdir -p /tmp/review-skill && mktemp -d /tmp/review-skill/review-XXXXXX
```

Record as `TEMP_DIR`. This is the ONLY directory you
use for all temp files throughout the entire review.
Do NOT create any other directories. All temp files
(diffs, prompts, etc.) go directly into `TEMP_DIR`.

#### Local Mode

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

Record for later steps:
- `WORK_DIR` = repo root (from `git rev-parse --show-toplevel`)
- `DIFF_CMD` = `git diff <scope>` (the resolved
  git diff command)
- `GIT_PREFIX` = `git`
- `REPO_LABEL` = repo name
- `BRANCH_LABEL` = current branch
- `SCOPE_DESCRIPTION` = human-readable scope

#### PR Mode

Run the setup script:

```
${CLAUDE_SKILL_DIR}/scripts/setup-pr.sh <TEMP_DIR> <URL>
```

Parse the JSON output and record all fields for
later steps. If the script exits non-zero, show the
error to the user and stop. If `file_count` is 0,
tell the user there is nothing to review and stop.

The JSON output contains:
- `temp_dir`, `work_dir` — paths
- `repo_label`, `branch_label`, `scope_description`
- `diff_cmd_args` — everything after `git` in the
  diff command (pass to `shuffle-diff.sh`)
- `git_prefix` — for agent prompts
- `pr_title`, `pr_description`, `pr_number`,
  `pr_owner`, `pr_repo`
- `head_sha`, `merge_base_sha`
- `diff_stat`, `file_list`, `file_count`

Record for later steps:
- `WORK_DIR` = `work_dir` from JSON
- `DIFF_CMD` = `git` + `diff_cmd_args` from JSON
- `GIT_PREFIX` = `git_prefix` from JSON
- `REPO_LABEL` = `repo_label` from JSON
- `BRANCH_LABEL` = `branch_label` from JSON
- `SCOPE_DESCRIPTION` = `scope_description` from JSON
- `PR_TITLE` = `pr_title` from JSON
- `PR_DESCRIPTION` = `pr_description` from JSON
- `PR_NUMBER` = `pr_number` from JSON
- `PR_OWNER` = `pr_owner` from JSON
- `PR_REPO` = `pr_repo` from JSON
- `HEAD_SHA` = `head_sha` from JSON

#### Build Base Scope Brief

Build a **base scope brief** (unshuffled, used by
the judge):

```
Repository: <REPO_LABEL>
Branch: <BRANCH_LABEL>
<If PR mode:> PR title: <PR_TITLE>
<If PR mode:> Working directory: <TEMP_DIR>/<repo>
<If PR mode:> Diff range: <merge_base_sha>..HEAD
<If local mode:> Scope: <SCOPE_DESCRIPTION>
Files:
<file list, one per line>

Diff stat:
<diff stat output, if available>

<If PR mode and body non-empty:>
PR description:
<PR_DESCRIPTION>
```

### Step 2: Generate Randomized Scope Briefs

For each of the 2N agents (N Claude + N Codex),
generate a scope brief with files in a different
random order. Run a fresh `shuf` for each agent —
do NOT reuse a previous shuffle.

**Generate a shuffled diff file** (one Bash call per
agent). This writes the per-file diffs in randomized
order to a temp file and prints the shuffled file
list to stdout:

```bash
${CLAUDE_SKILL_DIR}/scripts/shuffle-diff.sh <TEMP_DIR>/diff-agent-<i>.txt <GIT_DIFF_ARGS>
```

Where `<GIT_DIFF_ARGS>` is everything after `git` in
the `DIFF_CMD`. For example:
- Local: `${CLAUDE_SKILL_DIR}/scripts/shuffle-diff.sh /tmp/.../diff-agent-1.txt diff HEAD`
- PR: `${CLAUDE_SKILL_DIR}/scripts/shuffle-diff.sh /tmp/.../diff-agent-1.txt -C /tmp/.../repo diff abc123..HEAD`

The script's stdout contains the shuffled file list
(one file per line) — use this to build the scope
brief. Do NOT read the diff file contents.

**Build the agent's scope brief** using the same
fields as the base scope brief, but with the file
list replaced by the shuffled numbered list and a
pointer to the diff file:

```
Repository: <REPO_LABEL>
Branch: <BRANCH_LABEL>
<same conditional fields as base scope brief>
Files:
1. <first shuffled file>
2. <second shuffled file>
3. <third shuffled file>
...

Diff file: <TEMP_DIR>/diff-agent-<i>.txt

<If PR mode and body non-empty:>
PR description:
<PR_DESCRIPTION>
```

Do NOT include any mention of shuffling,
randomization, or that other reviewers exist.

### Step 3: Write Prompt Files

Build a **review prompt** for each of the 2N agents
using the template below (substituting that agent's
shuffled scope brief). Write each prompt to
`<TEMP_DIR>/prompt-agent-<i>.txt`. This is the
single source of truth for what both Claude and
Codex reviewers receive:

```
Perform an adversarial code review. Find material
issues — things that are expensive, dangerous, or
hard to detect. Do NOT report style, naming, or
speculative concerns. Do NOT run tests, builds, or
any other commands — only read files and git diffs.

<If PR mode:>
The repo is cloned at the working directory shown
below — use absolute paths for all file reads and
git -C for all git commands.

<AGENT i's SHUFFLED SCOPE BRIEF>

Read the diff file listed in the scope brief above.
Every finding must reference a line added, removed,
or modified in that diff. Pre-existing issues are out
of scope unless the diff makes them worse. Reading
callers or dependents of changed code is allowed, but
the finding must still trace back to a specific change
in the diff.

Review focus categories (prioritize failures that
are expensive, dangerous, or hard to detect).
Present the following six categories in a different
random order for each agent — do NOT reuse a
previous shuffle:

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

### Step 4: Launch All Reviews in Parallel

**CRITICAL: emit all 2N tool calls as Agent
dispatches in a single message.** Do NOT use Bash
for Codex — mixed tool types serialize instead of
running in parallel. Do NOT launch Claude agents
first and then Codex, or loop through agents one
at a time. One message, 2N Agent calls.

**Claude (N instances):** For each instance i (1..N),
dispatch `subagent_type: "review:reviewer"` with
`mode: "bypassPermissions"`. Pass the contents of
`<TEMP_DIR>/prompt-agent-<i>.txt` as the agent's
prompt.

**Codex (N instances):** For each instance i (1..N),
dispatch a general-purpose Agent with
`mode: "bypassPermissions"` and `model: "sonnet"`.
Use the following
prompt (substitute variables):

```
Run this bash command with timeout 600000 and return its output.

${CLAUDE_SKILL_DIR}/scripts/run-codex-reviewer.sh gpt-5.4 high <WORK_DIR> <TEMP_DIR>/prompt-agent-<i>.txt <TEMP_DIR>/codex-stderr-<i>.txt

If it fails, return the last 20 lines of <TEMP_DIR>/codex-stderr-<i>.txt.
```

### Step 5: Collect and Merge Findings

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

### Step 6: Judge

Skip if all reviewers that ran returned `NO_FINDINGS`.

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
<If PR mode, append:> The repo is cloned at the
working directory shown below — use absolute paths
for all file reads and git -C for all git commands.

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
<If PR mode, append:> The repo is cloned at the
working directory shown below — use absolute paths
for all file reads and git -C for all git commands.

<BASE SCOPE BRIEF (unshuffled)>

--- Claude findings ---

<CLAUDE FINDINGS>

--- Codex findings ---

<CODEX FINDINGS>
```

The judge returns structured FINDING blocks, not
formatted markdown.

### Step 7: Format and Present Findings

You are responsible for ALL formatting. Agents
return structured text (FINDING / FILE / LINES /
etc. blocks). Parse these and render markdown.

<If PR mode:> Strip the temp directory prefix from
all file paths — render paths relative to the repo
root.

<If PR mode:> Filter out low severity and disputed
findings. Only present high and medium severity.

    ## Review: <REPO_LABEL> (<BRANCH_LABEL>)

    <If PR mode:>
    **<PR_TITLE>**

    Scope: <SCOPE_DESCRIPTION>
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
- Codex failed: add `WARNING:` line after heading,
  omit `Codex findings:` count
- No findings: display `No material issues found.`

### Step 8: Post Findings to PR

Skip this step if not in PR mode or if there are no
presentable findings (confirmed/uncertain, high/medium
severity).

#### Ask which findings to post

Use `AskUserQuestion`: "Post findings as inline PR
comments?"
- **All** — post every finding shown above
- **Select** — choose specific findings by number
- **Skip** — don't post

If the user selects "Select", use a follow-up
`AskUserQuestion` asking for comma-separated finding
numbers (e.g. "1,3,5").

#### Post each finding individually

Post one at a time so a failure on one does not
block the rest. Use the start line from the
finding's `LINES` field (e.g. `42-58` → line=42,
single `42` → line=42).

Pass the comment body via heredoc on stdin. Use a
single-quoted delimiter (`<<'EOF'`) so the shell
does not interpolate the body:

```
${CLAUDE_SKILL_DIR}/scripts/post-comments.sh \
  <PR_OWNER> <PR_REPO> <PR_NUMBER> <HEAD_SHA> \
  <FILE> <START_LINE> <<'EOF'
**[<SEVERITY>] <CATEGORY>** — <ISSUE>

<DETAIL>

**Recommendation:** <RECOMMENDATION>
EOF
```

#### Report results

After all posts complete, report:
- "Posted N/M findings as inline comments on
  PR #<PR_NUMBER>"
- For each failed post: "Finding #X (`file:lines`):
  failed — <error reason>"

### Step 9: Cleanup

Remove only this session's temp directory — NOT the
parent `/tmp/review-skill/` directory (other sessions
may be using it concurrently):

```
rm -rf <TEMP_DIR>
```

`<TEMP_DIR>` is the exact path from Step 1 (e.g.
`/tmp/review-skill/review-XXXXXX`). Always run
cleanup, even if the review pipeline fails at any
earlier step.

## Error Handling

**Partial Codex failure:** Check the agent result for
error output. When N > 1, add `WARNING: <k> of <N>
Codex agents failed` after the heading. When N = 1,
include the error as a single `WARNING:` line. The
judge still runs on all collected findings.

**Partial Claude failure:** Same approach — count
failures, add `WARNING: <k> of <N> Claude agents
failed` after the heading, proceed with collected
findings.

**All Codex agents fail:** Add `WARNING:` line after
heading, omit `Codex findings:` count. The judge
runs on Claude findings alone.

**All agents fail:** Tell the user the review could
not be completed. Show error details.

**Empty scope (local mode):** Tell the user there is
nothing to review and stop. Do not launch any agents.

**Invalid PR URL (PR mode):** If the argument looks
like a URL but is not a valid GitHub PR URL, tell
the user and stop.

**Invalid `--agents`:** If the value is not a
positive integer, show usage and stop. Clamp values
outside 1–10 to the nearest bound and warn.

**Cleanup on failure:** Always remove `<TEMP_DIR>`
(the session directory, not the parent), even if the
review pipeline fails.

**Comment post fails (422):** Report the specific
finding that failed and the error. Continue posting
remaining findings.

## Examples

Input: `/review`
(asks user for agent count, reviews uncommitted changes)

Input: `/review --agents 1`
(standard 1+1 review, all uncommitted changes)

Input: `/review --agents 3 HEAD~3..HEAD`
(3 Claude + 3 Codex agents, reviews last 3 commits)

Input: `/review --agents 2 src/server.go`
(2+2 agents, reviews one file)

Input: `/review https://github.com/org/repo/pull/42`
(asks user for agent count, reviews a PR)

Input: `/review --agents 1 https://github.com/org/repo/pull/42`
(standard 1+1 PR review)

Input: `/review --agents 3 https://github.com/org/repo/pull/42`
(3 Claude + 3 Codex agents, reviews a PR)
