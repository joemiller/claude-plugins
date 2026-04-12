# CLAUDE.md

Personal Claude Code plugins repo. Monorepo of plugins installable via the marketplace manifest.

## Structure

```
.claude-plugin/marketplace.json   # top-level manifest listing all plugins
plugins/<name>/
  .claude-plugin/plugin.json      # plugin metadata (name, description, version)
  skills/<skill-name>/SKILL.md    # skill definitions (user-invocable)
  agents/<agent-name>.md          # agent definitions (dispatched by skills, not user-invocable)
```

## Current Plugins

- **review** — Multi-model code review with cross-validation. Runs Claude and Codex reviewers in parallel, then a judge agent validates/deduplicates findings.
  - Skills: `pr-review` (GitHub PR URL), `review` (local changes/ranges) — both support `--agents N` for multi-agent reviews
  - Agents: `reviewer` (adversarial reviewer, sonnet), `judge` (cross-validates findings, sonnet)

## Adding a New Plugin

1. Create `plugins/<name>/.claude-plugin/plugin.json` with name, description, version.
2. Add skills under `plugins/<name>/skills/<skill-name>/SKILL.md`.
3. Add agents under `plugins/<name>/agents/<agent-name>.md` if needed.
4. Register the plugin in `.claude-plugin/marketplace.json`.
