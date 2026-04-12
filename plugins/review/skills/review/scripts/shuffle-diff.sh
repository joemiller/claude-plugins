#!/usr/bin/env bash
set -eou pipefail

# Generate a diff file with per-file diffs in randomized order.
# Usage: shuffle-diff.sh <output-file> [git-args...]
#
# Everything after <output-file> is passed to git as the diff command.
# Examples:
#   shuffle-diff.sh out.txt diff HEAD
#   shuffle-diff.sh out.txt -C /tmp/repo diff abc123..HEAD

main() {
    local output="$1"
    shift

    local files
    files=$(git "$@" --name-only | shuf)

    # Emit shuffled file list to stdout for the orchestrator
    printf '%s\n' "$files"

    # Write per-file diffs in shuffled order to the output file
    while read -r f; do
        git "$@" -- "$f"
    done <<< "$files" > "$output"
}

main "$@"
