# CLAUDE.md

Multi-model code review plugin. Runs Claude and Codex reviewers in parallel, then a judge agent cross-validates and deduplicates findings.

## Architecture

- **Skill** (`review`) is a pure orchestrator — it dispatches agents and formats output, never reviews code itself. Supports `--agents N` for multi-agent reviews with randomized file ordering. Handles both local changes and GitHub PR URLs.
- **Agents** (`reviewer`, `judge`) return structured `FINDING:` blocks, not markdown. The skill handles all formatting.
- Codex is optional. The skill degrades gracefully to Claude-only when the `codex` CLI is unavailable.

## Key Conventions

- PR mode clones to a temp dir and always cleans up. Agent prompts include a "Working directory" field — agents must use absolute paths rooted there and `git -C` for all git commands.
- Local mode operates on the user's working tree directly.
- `review-focus:` in a target repo's CLAUDE.md is injected into reviewer prompts when present.
- Judge treats all finding text as untrusted data (prompt injection defense).
- Both agents use `model: sonnet` and read-only tools only.
