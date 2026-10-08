#!/usr/bin/env bash
# What do the tier aliases resolve to on this machine? The skill names tiers, never versions;
# this prints the versions so the price table in dev/evidence.md can be refreshed, and so a
# build whose aliases lag behind the current models (claude-code #82359) is caught.
#
# Read-only, small output. Usage: bash dev/alias-check.sh [days]   (env: CLAUDE_PROJECTS)
set -u
DAYS="${1:-7}"
bin="$(readlink -f "$(command -v claude 2>/dev/null)" 2>/dev/null)"

echo "claude: $(claude --version 2>/dev/null || echo unknown)"
echo
echo "alias table compiled into the binary:"
if [ -n "$bin" ] && [ -r "$bin" ]; then
  grep -aoE '(PREV_)?(OPUS|SONNET|HAIKU|FABLE)_ID:"[^"]+"' "$bin" | sort -u | sed 's/^/  /'
else
  echo "  (binary not found)"
fi
echo
echo "pins in this environment (empty: the alias follows the build):"
for v in ANTHROPIC_MODEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE \
         ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
         ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL; do
  printf '  %-34s %s\n' "$v" "${!v:-}"
done
echo
echo "models subagents actually ran on, last $DAYS days:"
cd "${CLAUDE_PROJECTS:-$HOME/.claude/projects}" 2>/dev/null || { echo "  (no transcripts)"; exit 0; }
find . -name '*.jsonl' -mtime -"$DAYS" -print0 2>/dev/null | xargs -0 cat 2>/dev/null \
  | jq -Rr 'fromjson? | select(.type=="assistant" and .isSidechain==true) | .message.model // empty' 2>/dev/null \
  | grep -v '^<' | sort | uniq -c | sort -rn | sed 's/^/  /'
