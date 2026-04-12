#!/usr/bin/env bash
set -eou pipefail

# Post a single inline review comment on a GitHub PR.
# Reads the comment body from stdin to avoid shell escaping issues.
#
# Usage: post-comments.sh <owner> <repo> <pr_number> <head_sha> <file> <line> <<'EOF'
#   comment body here
#   EOF

main() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local head_sha="$4"
    local file="$5"
    local line="$6"

    local body
    body=$(cat)

    gh api "repos/${owner}/${repo}/pulls/${pr_number}/comments" \
        -f commit_id="$head_sha" \
        -f path="$file" \
        -F line="$line" \
        -f side='RIGHT' \
        -f body="$body" \
        >/dev/null
}

main "$@"
