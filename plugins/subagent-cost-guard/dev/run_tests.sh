#!/usr/bin/env bash
# Self-check for hooks/agent-tier-gate.sh and hooks/session-start-context.sh. Run: bash dev/run_tests.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/hooks/agent-tier-gate.sh"
pass=0; fail=0

# Transcript fixtures: the gate reads the live session model off the last assistant record.
FX="$(mktemp -d "${TMPDIR:-/tmp}/cost-guard-tests.XXXXXX")"
trap 'rm -rf "$FX"' EXIT
rec() { printf '{"type":"assistant","message":{"role":"assistant","model":"%s","content":[]}}\n' "$1"; }
{ printf '{"type":"user","message":{"role":"user","content":"hi"}}\n'; rec claude-sonnet-5-5; } > "$FX/sonnet.jsonl"
{ rec claude-haiku-4-5-20251001; rec claude-opus-5-5; } > "$FX/opus.jsonl"       # last record wins
{ rec claude-opus-5-5; rec claude-haiku-4-5-20251001; } > "$FX/haiku.jsonl"
rec '<synthetic>' > "$FX/synthetic.jsonl"
{ printf '"content":[]}}\n'; rec claude-opus-5-5; } > "$FX/cut.jsonl"           # a tail cut mid-line
side() { printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","model":"%s","content":[]}}\n' "$1"; }
side claude-haiku-4-5-20251001 > "$FX/subagent.jsonl"                             # a subagent's own transcript
{ rec claude-opus-5-5; side claude-haiku-4-5-20251001; } > "$FX/mixed.jsonl"      # old format: main record wins
MISSING="$FX/does-not-exist.jsonl"

# Every run clears the mode and model env vars so a developer's shell cannot leak into a green run.
CLEAN=(env -u SUBAGENT_COST_GUARD_MODE -u CLAUDE_PLUGIN_OPTION_GATE_MODE
           -u CLAUDE_CODE_SUBAGENT_MODEL -u CLAUDE_CODE_SUBAGENT_MODEL_FORCE)
run() { local json="$1"; shift; printf '%s' "$json" | "${CLEAN[@]}" "$@" bash "$GATE"; }
reason() { run "$@" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }

# aj <subagent_type|""> <model|"-" to omit> <transcript_path|"">  — an Agent PreToolUse payload
aj() { jq -nc --arg st "$1" --arg m "$2" --arg tp "$3" '{hook_event_name:"PreToolUse",tool_name:"Agent"}
        + (if $tp=="" then {} else {transcript_path:$tp} end)
        + {tool_input:({prompt:"x"} + (if $st=="" then {} else {subagent_type:$st} end)
                                   + (if $m=="-" then {} else {model:$m} end))}'; }
# wj <script> <transcript_path|"">  — a Workflow PreToolUse payload
wj() { jq -nc --arg s "$1" --arg tp "$2" '{hook_event_name:"PreToolUse",tool_name:"Workflow"}
        + (if $tp=="" then {} else {transcript_path:$tp} end) + {tool_input:{script:$s}}'; }

ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

# assert <name> <expect: deny|noop> <json> [env assignment ...]
assert() {
  local name="$1" expect="$2" json="$3" out got; shift 3
  out="$(run "$json" "$@" 2>/dev/null)"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got=deny; else got=noop; fi
  [ "$got" = "$expect" ] && ok "$name" || bad "$name" "expected $expect, got $got: $out"
}
# assert_reason <name> <json> <grep -E pattern> [env ...]  — a deny whose reason matches
assert_reason() {
  local name="$1" json="$2" pat="$3" r; shift 3
  r="$(reason "$json" "$@")"
  [ -n "$r" ] && printf '%s' "$r" | grep -qE "$pat" && ok "$name" || bad "$name" "reason: $r"
}
# assert_no_reason <name> <json> <grep -E pattern> [env ...]  — a deny whose reason does not match
assert_no_reason() {
  local name="$1" json="$2" pat="$3" r; shift 3
  r="$(reason "$json" "$@")"
  [ -n "$r" ] && ! printf '%s' "$r" | grep -qE "$pat" && ok "$name" || bad "$name" "reason: $r"
}
# assert_warn <name> <json> [env ...] — warn mode must not block and must say something on stderr
assert_warn() {
  local name="$1" json="$2" out err; shift 2
  err="$(run "$json" "$@" 2>&1 >/dev/null)"
  out="$(run "$json" "$@" 2>/dev/null)"
  if printf '%s' "$out" | grep -q 'permissionDecision' || [ -z "$err" ]
  then bad "$name" "out=$out err=$err"; else ok "$name"; fi
}

NOMODEL="$(aj Explore - "")"

# --- no transcript, no env: the inherited model is unknown, so today's behaviour holds ---
assert 'Agent Explore, no model'          deny "$NOMODEL"
assert 'Agent Explore, model haiku'       noop "$(aj Explore haiku "")"
assert 'Agent general-purpose, no model'  deny "$(aj general-purpose - "")"
assert 'Agent Plan, no model'             deny "$(aj Plan - "")"
assert 'Agent claude, no model'           deny "$(aj claude - "")"
assert 'Agent no subagent_type, no model' deny "$(aj "" - "")"
assert 'Agent fork, no model'             noop "$(aj fork - "")"
assert 'Agent plugin agent, no model'     noop "$(aj feature-dev:code-reviewer - "")"
assert 'Agent Explore-like custom type'   noop "$(aj acme:custom-agent - "")"
assert 'Agent empty model string'         deny "$(aj Explore "" "")"
assert 'Workflow agent() no model'        deny "$(wj "export const meta={}; await agent('go')" "")"
assert 'Workflow no agent() call'         noop "$(wj "export const meta={}; log('hi')" "")"
assert 'Workflow resume by scriptPath'    noop '{"tool_name":"Workflow","tool_input":{"scriptPath":"/tmp/wf.js","resumeFromRunId":"wf_abc123"}}'
assert 'unrelated tool untouched'         noop '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
assert 'malformed json fails open'        noop 'not json at all'
assert 'empty stdin fails open'           noop ''
assert 'default mode denies'              deny "$NOMODEL"
assert 'env mode=deny denies'             deny "$NOMODEL" 'SUBAGENT_COST_GUARD_MODE=deny'
assert 'env mode=off bypasses'            noop "$NOMODEL" 'SUBAGENT_COST_GUARD_MODE=off'
assert 'plugin config mode=off bypasses'  noop "$NOMODEL" 'CLAUDE_PLUGIN_OPTION_GATE_MODE=off'
assert 'plugin config mode=deny denies'   deny "$NOMODEL" 'CLAUDE_PLUGIN_OPTION_GATE_MODE=deny'
assert 'env overrides plugin config'      noop "$NOMODEL" 'CLAUDE_PLUGIN_OPTION_GATE_MODE=deny' 'SUBAGENT_COST_GUARD_MODE=off'
assert 'typo in mode fails closed'        deny "$NOMODEL" 'SUBAGENT_COST_GUARD_MODE=of'
assert_warn 'env mode=warn does not block, notes on stderr' "$NOMODEL" 'SUBAGENT_COST_GUARD_MODE=warn'
assert_warn 'plugin config mode=warn does not block'        "$NOMODEL" 'CLAUDE_PLUGIN_OPTION_GATE_MODE=warn'

# --- the model value itself ---
assert        'Agent model inherit is an omission'      deny "$(aj Explore inherit "")"
assert_reason 'Agent model inherit names inherit'       "$(aj Explore inherit "")" 'inherit'
assert 'Agent bracketed alias counts as tiered'  noop "$(aj Explore 'sonnet[1m]' "")"
assert 'Agent full model id counts as tiered'    noop "$(aj general-purpose claude-opus-5-5 "")"

# --- CLAUDE_CODE_SUBAGENT_MODEL: what an untiered dispatch inherits when set ---
assert        'subagent default haiku passes'        noop "$NOMODEL" 'CLAUDE_CODE_SUBAGENT_MODEL=haiku'
assert        'subagent default sonnet passes'       noop "$NOMODEL" 'CLAUDE_CODE_SUBAGENT_MODEL=sonnet'
assert        'subagent default sonnet[1m] passes'   noop "$NOMODEL" 'CLAUDE_CODE_SUBAGENT_MODEL=sonnet[1m]'
assert        'subagent default opus denied'         deny "$NOMODEL" 'CLAUDE_CODE_SUBAGENT_MODEL=opus'
assert_reason 'subagent default opus named in reason' "$NOMODEL" 'CLAUDE_CODE_SUBAGENT_MODEL' 'CLAUDE_CODE_SUBAGENT_MODEL=opus'
assert        'subagent default fable id denied'     deny "$NOMODEL" 'CLAUDE_CODE_SUBAGENT_MODEL=claude-fable-5-1'
assert        'subagent model forced: nothing to gate' noop "$NOMODEL" 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1' 'CLAUDE_CODE_SUBAGENT_MODEL=opus'
assert        'two tiers named: the expensive one wins' deny "$NOMODEL" 'CLAUDE_CODE_SUBAGENT_MODEL=haiku-opus-eval'

# --- the live session model, read from the transcript ---
assert        'session haiku passes'                 noop "$(aj Explore - "$FX/haiku.jsonl")"
assert        'session sonnet passes'                noop "$(aj Explore - "$FX/sonnet.jsonl")"
assert        'session opus denied'                  deny "$(aj Explore - "$FX/opus.jsonl")"
assert_reason 'session opus named in reason'         "$(aj Explore - "$FX/opus.jsonl")" 'claude-opus-5-5'
assert        'session only synthetic: unknown, denied' deny "$(aj Explore - "$FX/synthetic.jsonl")"
assert        'transcript missing: unknown, denied'  deny "$(aj Explore - "$MISSING")"
assert_reason 'cut first line skipped, opus still read' "$(aj Explore - "$FX/cut.jsonl")" 'claude-opus-5-5'
assert        'nested dispatch inherits the subagent model' noop "$(aj Explore - "$FX/subagent.jsonl")"
assert_reason 'main record beats a later sidechain record' "$(aj Explore - "$FX/mixed.jsonl")" 'claude-opus-5-5'
assert 'env opus beats session sonnet'  deny "$(aj Explore - "$FX/sonnet.jsonl")" 'CLAUDE_CODE_SUBAGENT_MODEL=opus'
assert 'env haiku beats session opus'   noop "$(aj Explore - "$FX/opus.jsonl")"   'CLAUDE_CODE_SUBAGENT_MODEL=haiku'
assert 'session sonnet does not exempt fork logic'  noop "$(aj fork - "$FX/opus.jsonl")"

# --- Workflow: model and effort ---
W_BOTH="await agent('go',{model:'haiku', effort:'low'})"
W_MODEL="await agent('go',{model:'haiku'})"
W_EFFORT="await agent('go',{effort:'low'})"
W_NONE="export const meta={}; await agent('go')"
W_INHERIT="await agent('go',{model: 'inherit', effort:'low'})"
W_INHERIT_ML=$'await agent(\'go\', {\n  model:\n    "inherit",\n  effort: \'low\'\n})'
assert        'Workflow model and effort'            noop "$(wj "$W_BOTH" "$FX/opus.jsonl")"
assert        'Workflow model, no effort'            deny "$(wj "$W_MODEL" "$FX/opus.jsonl")"
assert_reason 'Workflow no effort names effort'      "$(wj "$W_MODEL" "$FX/opus.jsonl")" 'effort'
assert_no_reason 'Workflow no effort does not blame model' "$(wj "$W_MODEL" "$FX/opus.jsonl")" 'sets no `model`'
assert        'Workflow effort, no model, session opus' deny "$(wj "$W_EFFORT" "$FX/opus.jsonl")"
assert_reason 'Workflow no model names model'        "$(wj "$W_EFFORT" "$FX/opus.jsonl")" 'model'
assert        'Workflow effort, no model, session sonnet' noop "$(wj "$W_EFFORT" "$FX/sonnet.jsonl")"
assert_reason 'Workflow model inherit is an omission'  "$(wj "$W_INHERIT" "$FX/opus.jsonl")" 'model'
assert        'Workflow model inherit, session sonnet' noop "$(wj "$W_INHERIT" "$FX/sonnet.jsonl")"
assert_reason 'Workflow model inherit split over lines' "$(wj "$W_INHERIT_ML" "$FX/opus.jsonl")" 'model'
assert_reason 'Workflow neither, session opus, names both' "$(wj "$W_NONE" "$FX/opus.jsonl")" 'model.*effort|effort.*model'
assert_reason 'Workflow neither, session sonnet, effort only' "$(wj "$W_NONE" "$FX/sonnet.jsonl")" 'effort'
assert_no_reason 'Workflow neither, session sonnet, no model blame' "$(wj "$W_NONE" "$FX/sonnet.jsonl")" 'sets no `model`'

# --- SessionStart context hook ---
CTX="$ROOT/hooks/session-start-context.sh"

assert_ctx() {
  local name="$1" expect="$2" out
  export -n SUBAGENT_COST_GUARD_MODE CLAUDE_PLUGIN_OPTION_GATE_MODE 2>/dev/null || true
  case "$expect" in
    payload) out="$(printf '{}' | bash "$CTX" 2>/dev/null)"
             if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null 2>&1
             then ok "$name"; else bad "$name" "$out"; fi ;;
    pointer) out="$(printf '{}' | bash "$CTX" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext')"
             if printf '%s' "$out" | grep -q 'subagent-cost-guard:orchestrating-agents'
             then ok "$name"; else bad "$name" "$out"; fi ;;
    notable) out="$(printf '{}' | bash "$CTX" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext')"
             if printf '%s' "$out" | grep -qi 'Mechanical\|| *haiku *|'
             then bad "$name" "tier table leaked into the injection"; else ok "$name"; fi ;;
    off)     out="$(printf '{}' | env SUBAGENT_COST_GUARD_MODE=off bash "$CTX" 2>/dev/null)"
             if [ "$out" = "{}" ]; then ok "$name"; else bad "$name" "rules injected despite off: $out"; fi ;;
    offcfg)  out="$(printf '{}' | env CLAUDE_PLUGIN_OPTION_GATE_MODE=off bash "$CTX" 2>/dev/null)"
             if [ "$out" = "{}" ]; then ok "$name"; else bad "$name" "rules injected despite off: $out"; fi ;;
    failopen) out="$(printf '{}' | env PATH=/nonexistent /bin/bash "$CTX" 2>/dev/null)"
             if [ "$out" = "{}" ]; then ok "$name"; else bad "$name" "$out"; fi ;;
  esac
}

assert_ctx 'SessionStart emits additionalContext'      payload
assert_ctx 'SessionStart names the skill'              pointer
assert_ctx 'SessionStart does not copy the tier table' notable
assert_ctx 'SessionStart silent when mode=off (env)'   off
assert_ctx 'SessionStart silent when mode=off (config)' offcfg
assert_ctx 'SessionStart fails open without jq'        failopen

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
