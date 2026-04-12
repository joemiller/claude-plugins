# review

Multi-model code review plugin for Claude Code. Runs Claude and Codex reviews in parallel, then cross-validates findings.

## Attribution

The prompts and architecture in this plugin are derived from [@kelp](https://github.com/kelp)'s
[cross-review](https://github.com/kelp/kelp-claude-plugins/tree/main/plugins/cross-review) plugin.

## Differences from upstream

- **2 skills instead of 1** — upstream has a single `cross-review` skill. This plugin splits into `review` (local changes) and `pr-review` (GitHub PRs). Both support `--agents N` for multi-agent reviews with randomized file ordering per agent.
- **Judge agent replaces cross-validation** — upstream runs each model as a validator of the other's findings (bidirectional). This plugin uses a dedicated `judge` agent that validates and deduplicates all findings in one pass.
- **`pr-review` is a dedicated skill** — clones the repo to a temp dir, extracts PR metadata via `gh`, and cleans up after. Upstream handles this within its single skill.
- **No reconciliation step** — upstream has `--reconcile` for disputed findings to return to the originator for rebuttal.
- **Consolidated structure** — 1 plugin with 2 skills sharing 2 agents.
