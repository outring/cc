#!/usr/bin/env bash
# Does a change to the plugin's prose move a dispatch's tier? Old plugin bytes against new.
#
# Two arms, same fixture, same prompt, only the plugin varies:
#   old = the plugin as committed on BASE (default origin/main), exported with git archive
#   new = the plugin in the working tree
#
# Prompt 1 is a cross-file root-cause fix delegated to a subagent — the row the sonnet-first
# table moved from opus (Intellectual) to sonnet (Deep). Prompt 2 is the same task under
# pressure ("needs careful cross-file reasoning"), the bait for the escape clause the new
# general-purpose row dropped. PROMPT3=1 adds a workflow-authoring prompt to see whether every
# agent() gets model and effort.
#
# Isolation as in ab-injection.sh: --setting-sources project drops the real ~/.claude/CLAUDE.md
# and every other plugin; --strict-mcp-config drops MCP; --plugin-dir loads one arm.
#
# MANUAL ONLY — never run by CI. This spends real money: 20 live `claude -p` sessions at sonnet
# by default, capped at $0.40 per rep (about $0.10 each in practice). It passes --permission-mode bypassPermissions, which is
# safe here only because every arm runs against a synthetic fixture repo created fresh in
# mktemp -d, with no access to any real checkout. Prints raw material only — read every rep.
#
# Usage: bash dev/ab-micro.sh [reps]
#        env: MODEL=sonnet  BASE=origin/main  ARMS="old new"  WORK=<dir>  PROMPTS="1 2"  PROMPT3=1
set -u
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$PLUGIN/../.." && pwd)"
MODEL="${MODEL:-sonnet}"
BASE="${BASE:-origin/main}"
REPS="${1:-${REPS:-5}}"
ARMS="${ARMS:-old new}"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/ab-micro.XXXXXX")}"
mkdir -p "$WORK/out"
echo "work dir: $WORK"

# --- fixture: two retry policies that drifted apart; the fix spans three files ---
if [ ! -d "$WORK/repo" ]; then
  mk() { mkdir -p "$WORK/repo/$(dirname "$1")"; printf '%s\n' "$2" > "$WORK/repo/$1"; }
  mk src/http/client.ts    "export const retryPolicy = { attempts: 3, backoffMs: 200 };"
  mk src/http/pool.ts      "import { retryPolicy } from './client';
export const pool = { retry: retryPolicy };"
  mk src/queue/worker.ts   "const retryPolicy = { attempts: 1, backoffMs: 0 }; // copied from http long ago
export function runJob(job: () => void) { for (let i = 0; i < retryPolicy.attempts; i++) job(); }"
  mk src/queue/dispatch.ts "import { runJob } from './worker';
export function dispatch(job: () => void) { runJob(job); }"
  mk src/db/pg.ts          "export const pg = null;"
  mk config/prod.yaml      "retryPolicy: aggressive"
  mk docs/reliability.md   "Every outbound call and every queued job retries under one retryPolicy."
fi

# --- plugin arms: what ships, minus dev/ ---
rm -rf "$WORK/plugin-old" "$WORK/plugin-new"
mkdir -p "$WORK/plugin-old"
git -C "$REPO" archive "$BASE" plugins/subagent-cost-guard | tar -x -C "$WORK/plugin-old" --strip-components=2
cp -R "$PLUGIN" "$WORK/plugin-new"
rm -rf "$WORK/plugin-old/dev" "$WORK/plugin-new/dev"

P1='Queued jobs retry once but HTTP calls retry three times — the two retry policies have drifted apart. Find the root cause across the files involved and fix it so there is one policy. Delegate the investigation and the fix to a subagent using the Agent tool rather than doing it yourself.'
P2='Production incident: HTTP calls retry three times but queued jobs retry once, and we are losing jobs. This needs careful cross-file reasoning — the root cause spans several modules. Find it and fix it properly. Delegate the investigation and the fix to a subagent using the Agent tool rather than doing it yourself.'
P3='Use a workflow: for each file under src/, have an agent check whether it imports retryPolicy from src/http/client.ts, then have one agent summarise the findings. Write and run the workflow script.'
PROMPTS="${PROMPTS:-1 2}"; [ "${PROMPT3:-0}" = "1" ] && PROMPTS="$PROMPTS 3"
# A nested session must not inherit this session's identity, bridge sockets, effort or model pins;
# the gate always runs in deny mode.
NOCLAUDE="$(env | grep -oE '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT)=' | sed 's/=$//; s/^/-u /' | tr '\n' ' ')"

for arm in $ARMS; do
  for k in $PROMPTS; do
    case "$k" in 1) PROMPT="$P1";; 2) PROMPT="$P2";; 3) PROMPT="$P3";; esac
    for n in $(seq 1 "$REPS"); do
      out="$WORK/out/$MODEL-$arm-p$k-$n.jsonl"
      [ -s "$out" ] && { echo "skip $arm-p$k-$n"; continue; }
      rm -rf "$WORK/run"; cp -R "$WORK/repo" "$WORK/run"
      ( cd "$WORK/run" && env $NOCLAUDE SUBAGENT_COST_GUARD_MODE=deny timeout 600 claude -p "$PROMPT" \
          --model "$MODEL" --output-format stream-json --verbose --include-hook-events \
          --strict-mcp-config --setting-sources project --plugin-dir "$WORK/plugin-$arm" \
          --permission-mode bypassPermissions --no-session-persistence \
          --max-budget-usd 0.40 ) > "$out.part" 2>"$out.err"
      if grep -q '"type":"result"' "$out.part"; then mv "$out.part" "$out"; echo "done $arm-p$k-$n"
      else echo "FAIL $arm-p$k-$n — no result record, see $out.err"; fi
    done
  done
done

python3 - "$WORK"/out/*.jsonl <<'PY'
import json, re, sys, os

def blocks(path):
    for line in open(path, encoding='utf-8', errors='ignore'):
        try: yield json.loads(line)
        except ValueError: pass

for path in sorted(sys.argv[1:]):
    tools, results = [], []
    for d in blocks(path):
        m = d.get('message') or {}
        for b in m.get('content') or []:
            if not isinstance(b, dict): continue
            if b.get('type') == 'tool_use': tools.append((b.get('name'), b.get('input') or {}))
            elif b.get('type') == 'tool_result':
                t = b.get('content')
                if isinstance(t, list): t = ' '.join(x.get('text','') for x in t if isinstance(x, dict))
                results.append(str(t))
    agents = [i for n, i in tools if n == 'Agent']
    flows = [i for n, i in tools if n == 'Workflow']
    print('=' * 74)
    print(os.path.basename(path))
    print('  tools              :', ', '.join(n for n, _ in tools))
    print('  skills             :', [i.get('skill') for n, i in tools if n == 'Skill'] or 'none')
    print('  gate denials       :', sum('sets no `' in r for r in results))   # the gate's own marker
    print('  Agent calls        :', [(a.get('subagent_type'), a.get('model')) for a in agents] or 'NONE')
    for f in flows:
        calls = re.findall(r'agent\([^)]*\)', f.get('script') or '', re.S)
        print('  Workflow agent()   :', [(bool(re.search(r'model\s*:', c)), bool(re.search(r'effort\s*:', c))) for c in calls] or 'no agent() calls')
PY
