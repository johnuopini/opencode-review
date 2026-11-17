#!/usr/bin/env bash
# Posts the review as one PR comment when it has at least one finding line
# (`**<severity>** ...`). A clean review, or one with only notes, posts
# nothing: a clean PR gets no comment and no email. The match also takes the
# small slips a model makes (a list item, `1.`, `**High:**`), so a real finding
# is never dropped for its format.
#
# Usage: scripts/post-findings.sh <review.md>
# Env: CHECK, PR_NUMBER, GITHUB_TOKEN and the default GITHUB_* variables.
set -euo pipefail

review=$1
finding='^[[:space:]]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)?\*\*(critical|high|medium|low):?\*\*'

if ! grep -Eiq "$finding" "$review"; then
  echo "No findings: no comment posted."
  exit 0
fi
if [ -z "${PR_NUMBER:-}" ]; then
  echo "::warning::Not a pull request run: the findings are only in the step summary."
  exit 0
fi

run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
# Control characters other than tab and newline are dropped
text=$(LC_ALL=C tr -d '\000-\010\013-\037' <"$review")
# JSON string by hand, so the job needs no jq: escape backslash, quote and
# tab, then join the lines with \n
body=$(
  printf '%s\n\n[%s review run](%s)\n' "$text" "$CHECK" "$run_url" |
    LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g" |
    LC_ALL=C awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
)

payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
printf '{"body":"%s"}' "$body" >"$payload"

# The token goes in on stdin, so it never shows in the process list. No
# retry: a POST that timed out may still have created the comment.
printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" |
  curl -fsS -o /dev/null -X POST -H @- \
    -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" \
    --data-binary "@$payload" \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments"
echo "Posted the findings on #$PR_NUMBER."
