#!/usr/bin/env bash
# Comment test. scripts/post-findings.sh must post nothing when the review has
# no finding line, and post the review as one PR comment when it has one.
# A stub curl records the request; nothing goes over the network.
#
# Usage: test/post-findings.sh
# Review texts hold literal backticks, so single quotes are intended.
# shellcheck disable=SC2016
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is not on PATH"

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/post-findings.sh"
[ -f "$script" ] || fail "script not found: $script"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Stub curl: keeps its arguments, the header lines read from stdin and the
# --data-binary file
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CURL_LOG/args"
cat >"$CURL_LOG/headers"
for arg in "$@"; do
  case "$arg" in @-) ;; @*) cp "${arg#@}" "$CURL_LOG/payload" ;; esac
done
exit "${CURL_EXIT:-0}"
EOF
chmod +x "$work/bin/curl"

# run <review file> [VAR=value ...]: runs the script, output in $work/out
run() {
  local review=$1
  shift
  rm -rf "$work/log"
  mkdir -p "$work/log"
  env PATH="$work/bin:$PATH" CURL_LOG="$work/log" \
    GITHUB_TOKEN=test-token-not-secret GITHUB_API_URL=https://api.example.test \
    GITHUB_SERVER_URL=https://github.example.test GITHUB_REPOSITORY=owner/repo \
    GITHUB_RUN_ID=42 CHECK=security PR_NUMBER=7 "$@" \
    bash "$script" "$review" >"$work/out" 2>&1
}

silent() { # silent <name> <review text> [VAR=value ...]
  local name=$1 text=$2
  shift 2
  printf '%b' "$text" >"$work/review.md"
  run "$work/review.md" "$@" || fail "$name: exit $? ($(cat "$work/out"))"
  [ ! -e "$work/log/args" ] || fail "$name: posted a comment"
}

silent "clean security" 'No security findings at medium or higher.\n'
silent "clean code" 'No code review findings.\n' CHECK=code
silent "notes only" 'I read the diff and AGENTS.md.\n\nNo security findings at medium or higher.\n'
silent "empty reply" ''
silent "not a severity" '**info** `a.sh:1` — not a finding\n'
silent "not a severity, colon" '**Note:** I read the diff.\n'
silent "no pull request" '**high** `a.sh:1` — x — y\n' PR_NUMBER=
grep -q '::warning::' "$work/out" || fail "no pull request: no warning"

posts() { # posts <name> <review text>: a finding the model wrote off format
  local name=$1 text=$2
  printf '%b' "$text" >"$work/review.md"
  run "$work/review.md" || fail "$name: exit $? ($(cat "$work/out"))"
  [ -e "$work/log/args" ] || fail "$name: no comment posted"
}

posts "numbered" '1. **high** `a.sh:1` — x — y\n'
posts "numbered paren" '2) **medium** `a.sh:1` — x — y\n'
posts "plus bullet" '+ **critical** `a.sh:1` — x — y\n'
posts "colon in bold" '**High:** `a.sh:1` — x — y\n'

# Findings with quote, backslash, tab, CRLF and a bell, then a bullet finding
printf '**high** `k8s/app.yaml:12` — the "token" is printed: C:\\path\tend\r\n- **Medium** `a.sh:3` — x\a — y\n' \
  >"$work/review.md"
run "$work/review.md" || fail "findings: exit $? ($(cat "$work/out"))"
[ -e "$work/log/args" ] || fail "findings: no comment posted"
grep -qx 'https://api.example.test/repos/owner/repo/issues/7/comments' "$work/log/args" ||
  fail "findings: wrong URL: $(cat "$work/log/args")"
grep -qx 'Authorization: Bearer test-token-not-secret' "$work/log/headers" ||
  fail "findings: no auth header on stdin"
if grep -q test-token-not-secret "$work/log/args"; then
  fail "findings: token in curl arguments"
fi
jq -e . "$work/log/payload" >/dev/null || fail "findings: payload is not JSON: $(cat "$work/log/payload")"
printf '**high** `k8s/app.yaml:12` — the "token" is printed: C:\\path\tend\n- **Medium** `a.sh:3` — x — y\n\n[security review run](https://github.example.test/owner/repo/actions/runs/42)\n' \
  >"$work/expected"
jq -r .body "$work/log/payload" | diff -u "$work/expected" - || fail "findings: wrong body"

printf '**low** `b.kt:9` — x — y\n' >"$work/review.md"
run "$work/review.md" CHECK=code || fail "code finding: exit $?"
jq -r .body "$work/log/payload" | grep -qF '[code review run](' || fail "code finding: wrong run link"

if run "$work/review.md" CURL_EXIT=22; then
  fail "curl failure: script succeeded"
fi

echo "post-findings: all cases pass"
