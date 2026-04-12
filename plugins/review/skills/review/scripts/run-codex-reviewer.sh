#!/usr/bin/env bash
set -eou pipefail

# Run a codex reviewer agent with constrained settings.
# Locks down sandbox mode and full-auto so the calling
# agent cannot deviate from the intended invocation.
#
# Usage: run-codex-reviewer.sh <model> <reasoning_effort> <work_dir> <prompt_file> <stderr_file>
#
# stdout: codex output (review findings)
# stderr_file: codex stderr captured to file for diagnostics

main() {
    local model="$1"
    local reasoning_effort="$2"
    local work_dir="$3"
    local prompt_file="$4"
    local stderr_file="$5"

    codex exec \
        -m "$model" \
        --config model_reasoning_effort="$reasoning_effort" \
        --sandbox read-only \
        --full-auto \
        -C "$work_dir" \
        < "$prompt_file" \
        2>"$stderr_file"
}

main "$@"
