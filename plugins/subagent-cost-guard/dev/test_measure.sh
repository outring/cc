#!/usr/bin/env bash
# Self-check for dev/measure-baseline.sh against synthetic transcripts.
# Run: bash dev/test_measure.sh
#
# Covers the three defects found by hand: bucketing by file mtime instead of
# event timestamp, denials skipped because they carry no "tool_use" marker, and
# an unset model on a named agent counted as gateable.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/dev/measure-baseline.sh"
# Portable template: BSD mktemp accepts `-t prefix`, GNU coreutils rejects it
# ("too few X's"), leaving WORK empty and the fixtures writing to /.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/measure-test.XXXXXX")"
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj"
pass=0; fail=0

# Window is [SINCE, UNTIL). Timestamps are chosen to sit either side of both
# endpoints, so the boundary cases below are exercised rather than assumed.
IN=2026-09-01T00:00:00.000Z        # 1788220800, comfortably inside
OUT=2026-08-01T00:00:00.000Z       # 1785542400, far outside
LATE_IN=2026-09-01T00:03:19.000Z   # 1788220999, last second inside
JUST_OUT=2026-09-01T00:03:21.000Z  # 1788221001, first second after UNTIL
EARLY_OUT=2026-08-31T23:46:39.000Z # 1788219999, last second before SINCE
SINCE=1788220000
UNTIL=1788221000

use() {  # use <ts> <subagent_type> <model-json>
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"t%s","name":"Agent","input":{"subagent_type":"%s","model":%s}}]}}\n' \
    "$1" "$RANDOM$RANDOM" "$2" "$3"
}
denial() {  # denial <ts> <is_error> <tool_use_id>
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":%s,"content":"subagent-cost-guard: this Agent call sets no `model`, so it inherits the session default"}]}}\n' \
    "$1" "$3" "$2"
}
gated_use() {  # gated_use <ts> <id> — an Agent dispatch the gate would deny
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Agent","input":{"subagent_type":"Explore"}}]}}\n' \
    "$1" "$2"
}
bash_use() {  # bash_use <ts> <id> — an unrelated command, e.g. grepping the hook
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"grep -r sets-no hooks/"}}]}}\n' \
    "$1" "$2"
}

{
  use "$IN"  Explore '"haiku"'
  use "$IN"  Explore null
  use "$IN"  general-purpose '"sonnet"'
  use "$IN"  Plan '"opus"'
  use "$IN"  acme:custom-agent null        # unset but exempt
  use "$OUT" Explore null                  # outside the window
  gated_use "$IN" tDENY
  denial "$IN" true tDENY                  # correlates to a gated dispatch
  denial "$IN" false tDENY                 # not an error -> not a denial
  denial "$OUT" true tDENY                 # outside the window
  bash_use "$IN" tGREP
  denial "$IN" true tGREP                  # failed grep printing the text
  denial "$IN" true tGHOST                 # errored result, no such dispatch
  # dispatch inside the window, denial lands just after it: still counted
  gated_use "$LATE_IN" tSTRADDLE
  denial "$JUST_OUT" true tSTRADDLE
  # dispatch just before the window, denial lands inside: belongs to the
  # earlier window, so neither counted here nor reported as unmatched
  gated_use "$EARLY_OUT" tPRIOR
  denial "$IN" true tPRIOR
} > "$WORK/proj/session.jsonl"

# mtime far outside the window: bucketing must ignore it entirely
touch -t 202701010000 "$WORK/proj/session.jsonl"

OUTPUT="$(CLAUDE_PROJECTS="$WORK" bash "$SCRIPT" "$SINCE" "$UNTIL" 2>&1)"

check() {  # check <name> <regex>
  if printf '%s' "$OUTPUT" | grep -Eq "$2"; then
    pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else
    fail=$((fail+1)); printf 'FAIL %s — no match for %s\n' "$1" "$2"
  fi
}

check 'counts only in-window dispatches'      'Agent calls total *: 7'
check 'unset counted'                         'no explicit model *: 4'
check 'gateable excludes the named agent'     'gateable \(would deny\) *: 3'
check 'named agent counted exempt'            'exempt \(named\) *: 1'
check 'per-model: haiku'                      'haiku +1'
check 'per-model: sonnet'                     'sonnet +1'
check 'per-model: opus'                       'opus +1'
check 'denials counted, errors only, in-window' 'denials observed *: 2 '
check 'denial split by kind'                  'Agent 2, Workflow 0'
check 'denial text on a Bash result ignored'  'unmatched denial text *: 2'

# Every denial shape the hook emits, and option literals in any spacing or quoting.
mkdir -p "$WORK/p2/proj"
tu() {  # tu <id> <name> <input-json>
  jq -nc --arg ts "$IN" --arg id "$1" --arg n "$2" --argjson i "$3" \
    '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"tool_use",id:$id,name:$n,input:$i}]}}'
}
deny_wf() {  # deny_wf <id>
  jq -nc --arg ts "$IN" --arg id "$1" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,is_error:true,content:"subagent-cost-guard: this workflow script calls agent() but sets no `effort` anywhere."}]}}'
}
{
  tu tINH Agent '{"subagent_type":"Explore","model":"inherit"}'
  denial "$IN" true tINH
  tu tWFE Workflow '{"script":"await agent('"'go'"',{model:'"'sonnet'"'})"}'
  deny_wf tWFE
  tu tWFQ Workflow '{"script":"await agent(\"a\",{model: \"opus\", effort: \"high\"}); await agent(\"b\",{model : '"'haiku'"', effort:'"'low'"'})"}'
} > "$WORK/p2/proj/session.jsonl"
OUTPUT="$(CLAUDE_PROJECTS="$WORK/p2" bash "$SCRIPT" "$SINCE" "$UNTIL" 2>&1)"

check 'model inherit and effort-only denials counted' 'Agent 1, Workflow 1'
check 'double-quoted model counted'           ' 1  model:opus'
check 'spaced model counted'                  ' 1  model:haiku'
check 'double-quoted effort counted'          ' 1  effort:high'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
