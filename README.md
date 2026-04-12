# joemiller-plugins

Personal [Claude Code plugins](https://docs.anthropic.com/en/docs/claude-code/plugins) marketplace.

## Install

Add the marketplace:

```
/plugin marketplace add joemiller/claude-plugins
```

Then install individual plugins:

```
/plugin install <plugin-name>@joemiller-plugins
```

## Plugins

| Plugin | Description |
|--------|-------------|
| [review](plugins/review/) | Multi-model code review with cross-validation. Runs Claude and Codex reviewers in parallel, then a judge agent validates and deduplicates findings. |

## Attribution

The review plugin is derived from [@kelp](https://github.com/kelp)'s
[cross-review](https://github.com/kelp/kelp-claude-plugins/tree/main/plugins/cross-review) plugin.
