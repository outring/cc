#!/usr/bin/env bash
# subagent-cost-guard: SessionStart hook — carries the standing dispatch rules the gate cannot.
#
# PreToolUse supports no additionalContext, so the gate can only deny after the fact. This hook
# puts the pointer and the un-gateable rules (state the tier, script before agents, cheap fans
# out) into context before the first dispatch.
#
# The tier table deliberately stays in the skill. An in-context summary that looks sufficient is
# why the skill stopped being read.
#
# Fails open: missing jq or unreadable payload emits {} and injects nothing.
set -u

noop() { printf '{}\n'; exit 0; }

MODE="${SUBAGENT_COST_GUARD_MODE:-${CLAUDE_PLUGIN_OPTION_GATE_MODE:-deny}}"
[ "$MODE" = "off" ] && noop     # off means off: no gate, and no rules either

DIR="${0%/*}"
command -v jq >/dev/null 2>&1 || noop
[ -r "$DIR/session-context.md" ] || noop

body="$(cat "$DIR/session-context.md" 2>/dev/null)" || noop
[ -n "$body" ] || noop

jq -nc --arg c "$body" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null || noop
