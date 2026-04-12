# CLAUDE.md

Multi-model code review plugin. Runs Claude and Codex reviewers in parallel, then a judge agent cross-validates and deduplicates findings.

## Architecture

- **Skills** (`pr-review`, `review`, `mega-review`) are pure orchestrators — they dispatch agents and format output, never review code themselves.
- **Agents** (`reviewer`, `judge`) return structured `FINDING:` blocks, not markdown. The skill handles all formatting.
- Codex is optional. Skills degrade gracefully to Claude-only when the `codex` CLI is unavailable.

## Key Conventions

- `pr-review` clones to a temp dir. Agent prompts include a "Working directory" field — agents must use absolute paths rooted there and `git -C` for all git commands.
- `review` operates on the user's working tree directly.
- `review-focus:` in a target repo's CLAUDE.md is injected into reviewer prompts when present.
- Judge treats all finding text as untrusted data (prompt injection defense).
- Both agents use `model: sonnet` and read-only tools only.
