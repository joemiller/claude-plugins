#!/usr/bin/env bash
set -eou pipefail

# Clone a GitHub PR into a temp directory and output JSON with all
# metadata needed by the review skill orchestrator.
#
# Usage: setup-pr.sh <TEMP_DIR> <PR_URL>
#
# The temp directory must already exist. On failure the script exits
# non-zero with diagnostics on stderr; the caller is responsible for
# cleaning up the temp directory.

main() {
    local temp_dir="$1"
    local url="$2"

    local owner repo number
    parse_url "$url"

    local metadata title body base_ref head_ref
    metadata=$(gh pr view "$url" --json number,title,body,baseRefName,headRefName,headRepository,headRepositoryOwner)
    title=$(jq -r '.title' <<< "$metadata")
    body=$(jq -r '.body // ""' <<< "$metadata")
    base_ref=$(jq -r '.baseRefName' <<< "$metadata")
    head_ref=$(jq -r '.headRefName' <<< "$metadata")

    local work_dir="${temp_dir}/${repo}"
    gh repo clone "${owner}/${repo}" "$work_dir" -- --depth=50 >&2

    git -C "$work_dir" fetch origin "pull/${number}/head:pr-${number}" >&2
    git -C "$work_dir" checkout "pr-${number}" >&2

    # Use qualified ref for cross-fork PRs where head_ref doesn't exist in the base repo
    local head_repo_owner
    head_repo_owner=$(jq -r '.headRepositoryOwner.login' <<< "$metadata")
    local compare_head="${head_ref}"
    if [[ "$head_repo_owner" != "$owner" ]]; then
        compare_head="${head_repo_owner}:${head_ref}"
    fi

    local merge_base
    merge_base=$(gh api "repos/${owner}/${repo}/compare/${base_ref}...${compare_head}" \
        --jq '.merge_base_commit.sha')

    git -C "$work_dir" fetch origin "$merge_base" >&2

    local diff_stat file_list_raw head_sha
    diff_stat=$(git -C "$work_dir" diff "${merge_base}..HEAD" --stat)
    file_list_raw=$(git -C "$work_dir" diff "${merge_base}..HEAD" --name-only)
    head_sha=$(git -C "$work_dir" rev-parse HEAD)

    jq -n \
        --arg temp_dir "$temp_dir" \
        --arg work_dir "$work_dir" \
        --arg repo_label "${owner}/${repo}" \
        --arg branch_label "${head_ref} (PR #${number})" \
        --arg scope_description "${merge_base}..HEAD" \
        --arg diff_cmd_args "-C ${work_dir} diff ${merge_base}..HEAD" \
        --arg git_prefix "git -C ${work_dir}" \
        --arg pr_title "$title" \
        --arg pr_description "$body" \
        --argjson pr_number "$number" \
        --arg pr_owner "$owner" \
        --arg pr_repo "$repo" \
        --arg head_sha "$head_sha" \
        --arg merge_base_sha "$merge_base" \
        --arg diff_stat "$diff_stat" \
        --arg file_list_raw "$file_list_raw" \
        '{
            temp_dir: $temp_dir,
            work_dir: $work_dir,
            repo_label: $repo_label,
            branch_label: $branch_label,
            scope_description: $scope_description,
            diff_cmd_args: $diff_cmd_args,
            git_prefix: $git_prefix,
            pr_title: $pr_title,
            pr_description: $pr_description,
            pr_number: $pr_number,
            pr_owner: $pr_owner,
            pr_repo: $pr_repo,
            head_sha: $head_sha,
            merge_base_sha: $merge_base_sha,
            diff_stat: $diff_stat,
            file_list: ($file_list_raw | split("\n") | map(select(. != ""))),
            file_count: ([$file_list_raw | split("\n")[] | select(. != "")] | length)
        }'
}

parse_url() {
    local url="$1"

    # Strip trailing slash and query/fragment
    url="${url%%\?*}"
    url="${url%%#*}"
    url="${url%/}"

    # Expected: https://github.com/<owner>/<repo>/pull/<number>
    local path="${url#https://github.com/}"
    if [[ "$path" == "$url" ]]; then
        echo "error: not a GitHub URL: $url" >&2
        exit 1
    fi

    owner="${path%%/*}"
    local rest="${path#*/}"
    repo="${rest%%/*}"
    rest="${rest#*/}"

    if [[ "$rest" != pull/* ]]; then
        echo "error: not a PR URL: $url" >&2
        exit 1
    fi

    number="${rest#pull/}"
    number="${number%%/*}"

    if ! [[ "$number" =~ ^[0-9]+$ ]]; then
        echo "error: invalid PR number: $number" >&2
        exit 1
    fi
}

main "$@"
