# review

Multi-model code review plugin for Claude Code. Dispatches Claude and Codex reviewers in parallel, then a judge agent cross-validates and deduplicates findings.

## Install

```
/plugin install review@joemiller-plugins
```

## Usage

```
/review                          # uncommitted changes
/review --staged                 # staged changes only
/review HEAD~3..HEAD             # git range
/review src/parser.ts            # specific files
/review https://github.com/org/repo/pull/123   # GitHub PR
```

Use `--agents N` to run N reviewers per model (default asks interactively):

```
/review --agents 3               # 3 Claude + 3 Codex reviewers
/review --agents 1 https://github.com/org/repo/pull/42
```

## How it works

1. Resolves scope to a diff (local changes or PR)
2. Generates N shuffled copies of the diff (randomized file order per reviewer to broaden coverage)
3. Launches N Claude + N Codex reviewers in parallel, each performing an adversarial review
4. A judge agent validates findings against the actual code, deduplicates, and produces a merged report
5. In PR mode, optionally posts findings as inline PR comments

Each reviewer focuses on material issues: trust boundaries, resource leaks, race conditions, input validation, error handling, and state corruption. Style and naming nits are explicitly excluded.

## Requirements

- `git`, `jq`, `shuf` (coreutils)
- `gh` — PR mode only
- `codex` CLI — optional; falls back to Claude-only when unavailable

## Architecture

- **Skill** (`review`) — pure orchestrator. Dispatches agents and formats output, never reviews code itself.
- **Agents** (`reviewer`, `judge`) — return structured `FINDING:` blocks. The skill handles all formatting.

## Attribution

Prompts and architecture derived from [@kelp](https://github.com/kelp)'s [cross-review](https://github.com/kelp/kelp-claude-plugins/tree/main/plugins/cross-review) plugin.

### Differences from upstream

- **Single unified skill** — handles both local changes and GitHub PRs, with `--agents N` for multi-agent reviews
- **Judge agent replaces cross-validation** — upstream runs each model as a validator of the other's findings (bidirectional); this plugin uses a dedicated judge that validates all findings in one pass
- **No reconciliation step** — upstream has `--reconcile` for disputed findings to return to the originator for rebuttal
