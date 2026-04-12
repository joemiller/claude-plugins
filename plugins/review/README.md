# review

Multi-model code review plugin for Claude Code. Runs Claude and Codex reviews in parallel, then cross-validates findings.

## Attribution

The prompts and architecture in this plugin are derived from [@kelp](https://github.com/kelp)'s
[cross-review](https://github.com/kelp/kelp-claude-plugins/tree/main/plugins/cross-review) plugin.

## Differences from upstream

- **Single unified skill** — upstream has a single `cross-review` skill. This plugin has a single `review` skill that handles both local changes and GitHub PRs, with `--agents N` for multi-agent reviews and randomized file ordering per agent.
- **Judge agent replaces cross-validation** — upstream runs each model as a validator of the other's findings (bidirectional). This plugin uses a dedicated `judge` agent that validates and deduplicates all findings in one pass.
- **No reconciliation step** — upstream has `--reconcile` for disputed findings to return to the originator for rebuttal.
