#!/usr/bin/env bash
# subagent-cost-guard: PreToolUse gate — no dispatch leaves without a deliberate model tier.
#
# Untiered dispatch was the overwhelming default across the recorded history, and
# documentation alone did not move it. Figures: dev/evidence.md.
#
# Gated:   Agent calls on generic types (Explore, general-purpose, Plan, claude, or unset)
#          whose `model` is unset or "inherit"; Workflow scripts that call agent() with no
#          `model:` other than 'inherit', or no `effort:`, anywhere.
# Passes:  a dispatch that would inherit haiku or sonnet. What it inherits is
#          CLAUDE_CODE_SUBAGENT_MODEL if set, else the live session model read from the
#          transcript. The gate exists to stop silent inheritance of opus or fable; a model it
#          cannot read is treated as expensive.
# Exempt:  `fork` (model is ignored there by design), named/plugin agents (their own definition
#          sets the model), and CLAUDE_CODE_SUBAGENT_MODEL_FORCE (every subagent is pinned).
# Modes:   gate_mode / SUBAGENT_COST_GUARD_MODE unset|deny -> block; warn -> stderr note only; off -> no-op.
# Fails open: any unexpected input, missing jq, or parse error emits {} and blocks nothing.
set -u

noop() { printf '{}\n'; exit 0; }

MODE="${SUBAGENT_COST_GUARD_MODE:-${CLAUDE_PLUGIN_OPTION_GATE_MODE:-deny}}"
[ "$MODE" = "off" ] && noop
[ -n "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" ] && noop
command -v jq >/dev/null 2>&1 || noop

payload="$(cat 2>/dev/null)" || noop
[ -n "$payload" ] || noop
printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || noop

# warn mode is stderr only: PreToolUse does not support additionalContext, so a
# non-blocking note cannot be injected into model context. Transcript-visible only.
stop() {
  if [ "$MODE" = "warn" ]; then
    printf 'subagent-cost-guard: %s\n' "$1" >&2
    noop
  fi
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

TIERS='default tier is `sonnet` (effort medium; high for cross-file work); `haiku` low for mechanical sweeps and extraction; `opus` high only to verify, synthesise or decide architecture; `fable` only after opus has failed twice'
SOFTEN='Soften with gate_mode=warn in the plugin config (/plugin), or SUBAGENT_COST_GUARD_MODE=warn for one session; off disables it.'

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" || noop
case "$tool" in Agent|Workflow) ;; *) noop ;; esac

# What an untiered dispatch inherits: the configured subagent default, else the live session
# model — the last assistant record in the transcript, so a mid-session /model switch counts.
# A subagent's own dispatches carry that subagent's transcript, so they inherit its model, as
# Claude Code does. Workflow agent() is assumed to resolve the same way; the docs do not say.
tier() {
  # The most expensive tier named wins, so a value naming two tiers fails toward deny.
  case "$1" in
    *fable*|*mythos*) echo fable ;;
    *opus*)           echo opus ;;
    *sonnet*)         echo sonnet ;;
    *haiku*)          echo haiku ;;
    *)                echo unknown ;;
  esac
}
inherited="${CLAUDE_CODE_SUBAGENT_MODEL:-}"
if [ -n "$inherited" ]; then
  inherits="inherits \`$inherited\` (CLAUDE_CODE_SUBAGENT_MODEL)"
else
  transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    # A byte-bounded tail keeps the hook fast; fromjson? skips the cut first line. A main
    # transcript's own records win; a subagent transcript holds only sidechain records.
    inherited="$(tail -c 262144 "$transcript" 2>/dev/null \
      | jq -Rr 'fromjson? | select(.type=="assistant") | "\(.isSidechain // false) \(.message.model // "")"' 2>/dev/null \
      | awk '$2 != "" && $2 !~ /^</ { if ($1 == "false") main = $2; else side = $2 } END { print (main != "" ? main : side) }')"
  fi
  if [ -n "$inherited" ]; then
    inherits="inherits \`$inherited\` (the session model)"
  else
    inherits="inherits the session model, which this hook could not read — assume the most expensive"
  fi
fi
case "$(tier "$inherited")" in haiku|sonnet) cheap=1 ;; *) cheap=0 ;; esac

case "$tool" in
  Agent)
    subtype="$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)"
    model="$(printf '%s' "$payload" | jq -r '.tool_input.model // ""' 2>/dev/null)"
    case "$model" in ""|inherit) ;; *) noop ;; esac   # any alias, [1m] variant or full id is a tier
    case "$subtype" in
      ""|Explore|general-purpose|Plan|claude) ;;
      *) noop ;;   # fork, and every named or plugin agent, keep their own model
    esac
    [ "$cheap" = 1 ] && noop
    how="sets no \`model\`"
    [ "$model" = inherit ] && how="sets no \`model\` tier — \`inherit\` is the same as omitting it"
    stop "subagent-cost-guard: this Agent call ${how}, so it ${inherits}. Choose the tier deliberately — ${TIERS}. Re-send the same call with \`model\` set; see the \`subagent-cost-guard:orchestrating-agents\` skill for the agent-type table. Exempt: subagent_type \"fork\" and named plugin agents. ${SOFTEN}"
    ;;
  Workflow)
    script="$(printf '%s' "$payload" | jq -r '.tool_input.script // ""' 2>/dev/null)"
    [ -n "$script" ] || noop                                   # scriptPath / name resumption
    flat="$(printf '%s' "$script" | tr '\n\r\t' '   ')"   # an option split over lines still counts
    printf '%s' "$flat" | grep -qE 'agent[[:space:]]*\(' || noop
    # Ceiling: one `model:` (or `effort:`) anywhere clears that check for the whole script, so
    # a 5-stage workflow that tiers one stage passes. Deliberate — counting agent( against the
    # options would false-deny on comments, helper functions and strings, and a false deny has
    # no remedy but switching the gate off. This catches zero tiering, not partial.
    missing=""
    printf '%s' "$flat" | sed -E "s/model[[:space:]]*:[[:space:]]*['\"]inherit['\"]//g" \
      | grep -qE 'model[[:space:]]*:' || [ "$cheap" = 1 ] || missing='`model`'   # model: 'inherit' is an omission
    printf '%s' "$flat" | grep -qE 'effort[[:space:]]*:' || missing="${missing:+$missing and }\`effort\`"
    [ -n "$missing" ] || noop
    stop "subagent-cost-guard: this workflow script calls agent() but sets no ${missing} anywhere. Without \`model\` every stage ${inherits}; without \`effort\` every stage inherits the session effort, and the Sonnet and Opus defaults differ. Give each agent() an explicit \`model\` and \`effort\` — ${TIERS}. ${SOFTEN}"
    ;;
esac
noop
