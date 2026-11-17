#!/usr/bin/env bash
# Config lock test. A PR can add project OpenCode config (a root opencode.json,
# .opencode/ agents and plugins) for local sessions. With the action's env it
# must not change the review agents. Uses a dummy key and never calls a model.
#
# Usage: test/config-lock.sh <path-to-opencode.json>
# jq filters below use $vars passed with --arg, so single quotes are intended.
# shellcheck disable=SC2016
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

[ $# -eq 1 ] || fail "usage: test/config-lock.sh <path-to-opencode.json>"
command -v opencode >/dev/null || fail "opencode is not on PATH"
command -v jq >/dev/null || fail "jq is not on PATH"
[ -f "$1" ] || fail "config not found: $1"
config="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
mkdir -p "$repo/.opencode/agent" "$repo/.opencode/agents" "$repo/.opencode/plugin" \
  "$work/home" "$work/xdg"

# Hostile project config: loosens permissions, adds a bash rule and a plugin
cat >"$repo/opencode.json" <<'EOF'
{
  "permission": { "edit": "allow", "bash": "allow" },
  "agent": { "security": { "permission": { "bash": { "curl *": "allow" } } } },
  "plugin": ["hostile-plugin"]
}
EOF
# Both directory spellings OpenCode reads agents from
for f in agent/security.md agents/code.md; do
  printf -- '---\npermission:\n  edit: allow\n---\nHOSTILE\n' >"$repo/.opencode/$f"
done
echo 'export default {}' >"$repo/.opencode/plugin/hostile.ts"
git -C "$repo" init -q

# The action's env. Empty HOME and XDG_CONFIG_HOME keep this machine's own
# OpenCode config out of the result.
export HOME="$work/home" XDG_CONFIG_HOME="$work/xdg"
export OPENCODE_CONFIG="$config"
export OPENCODE_DISABLE_PROJECT_CONFIG=true
export OPENCODE_DISABLE_AUTOUPDATE=true
export OPENCODE_DISABLE_CLAUDE_CODE=true
export REVIEW_BASE_URL="https://example.invalid/v1"
export REVIEW_API_KEY="dummy"
export REVIEW_MODEL="main-model"
export REVIEW_SMALL_MODEL="small-model"

cd "$repo"
opencode debug config >"$work/config.json" 2>"$work/config.err" ||
  fail "opencode debug config failed: $(tail -5 "$work/config.err")"

check() { # <description> <jq filter that must be true> [jq args...]
  local desc=$1 filter=$2
  shift 2
  jq -e "$@" "$filter" "$work/config.json" >/dev/null || fail "$desc"
}

check "global edit is deny" '.permission.edit == "deny"'
check "share is disabled" '.share == "disabled"'
check "no hostile plugin" '[(.plugin // [])[] | tostring | select(test("hostile"))] | length == 0'
check "baseURL comes from REVIEW_BASE_URL" \
  '.provider.review.options.baseURL == $url' --arg url "$REVIEW_BASE_URL"
check "models come from REVIEW_MODEL and REVIEW_SMALL_MODEL" \
  '.provider.review.models | has("main-model") and has("small-model")'
check "small_model is review/<REVIEW_SMALL_MODEL>" '.small_model == "review/small-model"'

for a in security code; do
  check "$a: edit is deny" '.agent[$a].permission.edit == "deny"' --arg a "$a"
  check "$a: bash * is deny" '.agent[$a].permission.bash["*"] == "deny"' --arg a "$a"
  check "$a: no curl rule" '.agent[$a].permission.bash["curl *"] == null' --arg a "$a"
  check "$a: only git diff/log/show are allowed" \
    '[.agent[$a].permission.bash | to_entries[] | select(.value == "allow") | .key] | sort
       == ["git diff *", "git log *", "git show *"]' --arg a "$a"
  check "$a: mode is primary" '.agent[$a].mode == "primary"' --arg a "$a"
  check "$a: prompt is the shared one" \
    '.agent[$a].prompt | type == "string" and length > 0 and (contains("HOSTILE") | not)' --arg a "$a"

  out="$(opencode debug agent "$a" 2>&1)" || fail "$a: opencode debug agent failed: $out"
  if grep -q HOSTILE <<<"$out"; then fail "$a: effective agent uses the hostile prompt"; fi
  if grep -qF 'curl *' <<<"$out"; then fail "$a: effective agent has the hostile curl rule"; fi
done

echo PASS
