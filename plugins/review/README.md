# review

Multi-model code review plugin for Claude Code. Runs Claude and Codex reviews in parallel, then cross-validates findings.

## Attribution

The prompts and architecture in this plugin are derived from [@kelp](https://github.com/kelp)'s
[cross-review](https://github.com/kelp/kelp-claude-plugins/tree/main/plugins/cross-review) plugin.

## Differences from upstream

- **3 skills instead of 1** — upstream has a single `cross-review` skill. This plugin splits into `review` (local changes), `pr-review` (GitHub PRs), and `mega-review` (multi-agent with randomized file ordering).
- **Judge agent replaces cross-validation** — upstream runs each model as a validator of the other's findings (bidirectional). This plugin uses a dedicated `judge` agent that validates and deduplicates all findings in one pass.
- **`mega-review` is new** — launches N agents per model with randomized file ordering to increase coverage. No equivalent upstream.
- **`pr-review` is a dedicated skill** — clones the repo to a temp dir, extracts PR metadata via `gh`, and cleans up after. Upstream handles this within its single skill.
- **No reconciliation step** — upstream has `--reconcile` for disputed findings to return to the originator for rebuttal.
- **Consolidated structure** — the original 2-plugin layout was merged into 1 plugin with 3 skills sharing 2 agents.
