#!/usr/bin/env bash
# Does the SessionStart hook carry the dispatch rules as well as CLAUDE.md did?
#
# Three arms, byte-identical rule text, only the delivery varies:
#   a = rules in a project CLAUDE.md   (the placement this plugin replaced)
#   b = rules in the SessionStart hook (what ships)
#   c = rules nowhere                  (control: skill description + gate only)
#
# Isolation: --setting-sources project drops the real ~/.claude/CLAUDE.md and every other
# plugin; --strict-mcp-config drops MCP; --plugin-dir loads one plugin variant.
#
# The gate stays in deny mode, so a rep that forgets `model` is blocked before any subagent
# runs. Prints raw material only — read every rep by hand, do not trust a grep count.
#
# MANUAL ONLY — never run by CI. This spends real money: 15 live `claude -p` sessions at
# opus by default, roughly $9, capped at $0.60 per rep. It passes --permission-mode
# bypassPermissions, which is safe here only because every arm runs against a synthetic
# fixture repo created fresh in mktemp -d, with no access to any real checkout.
#
# Usage: bash dev/ab-injection.sh [reps]   (env: MODEL=opus, WORK=<dir>, ARMS="a b c")
set -u
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${MODEL:-opus}"
REPS="${1:-${REPS:-5}}"
ARMS="${ARMS:-a b c}"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/ab-injection.XXXXXX")}"
mkdir -p "$WORK/out"
echo "work dir: $WORK"

# --- fixture: a repo whose sweep is unambiguously mechanical ---
if [ ! -d "$WORK/repo" ]; then
  mk() { mkdir -p "$WORK/repo/$(dirname "$1")"; printf '%s\n' "$2" > "$WORK/repo/$1"; }
  mk src/http/client.ts    "export const retryPolicy = { attempts: 3 };"
  mk src/http/pool.ts      "import { retryPolicy } from './client';"
  mk src/http/headers.ts   "export const defaultHeaders = {};"
  mk src/queue/worker.ts   "// retryPolicy is applied per job"
  mk src/queue/dispatch.ts "export function dispatch() { return 1; }"
  mk src/db/pg.ts          "export const pool = null;"
  mk src/db/migrate.ts     "// no retry here"
  mk src/cache/lru.ts      "export class Lru {}"
  mk config/prod.yaml      "retryPolicy: aggressive"
  mk config/dev.yaml       "logLevel: debug"
  mk docs/reliability.md   "See retryPolicy for backoff details."
  mk docs/setup.md         "Install and run."
fi

# --- plugin variants: base is this plugin minus the SessionStart hook ---
rm -rf "$WORK/plugin-base"
cp -R "$PLUGIN" "$WORK/plugin-base"
rm -rf "$WORK/plugin-base/dev" "$WORK/plugin-base/hooks/session-start-context.sh"
python3 -c "
import json,sys
p='$WORK/plugin-base/hooks/hooks.json'
d=json.load(open(p)); d['hooks'].pop('SessionStart',None)
json.dump(d,open(p,'w'),indent=2,ensure_ascii=False)"

for arm in $ARMS; do
  rm -rf "$WORK/repo-$arm"; cp -R "$WORK/repo" "$WORK/repo-$arm"
done
# arm a carries the same bytes the hook injects, through the CLAUDE.md wrapper instead
[ -d "$WORK/repo-a" ] && cp "$PLUGIN/hooks/session-context.md" "$WORK/repo-a/CLAUDE.md"

# A nested session must not inherit this session's identity, bridge sockets, effort or model pins;
# the gate always runs in deny mode.
NOCLAUDE="$(env | grep -oE '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT)=' | sed 's/=$//; s/^/-u /' | tr '\n' ' ')"

PROMPT='Sweep this repo and list every file path that mentions retryPolicy. Delegate the sweep to a subagent using the Agent tool rather than searching yourself.'

for arm in $ARMS; do
  case "$arm" in b) PDIR="$PLUGIN";; *) PDIR="$WORK/plugin-base";; esac
  for n in $(seq 1 "$REPS"); do
    out="$WORK/out/$MODEL-$arm-$n.jsonl"
    [ -s "$out" ] && { echo "skip $arm-$n"; continue; }
    ( cd "$WORK/repo-$arm" && env $NOCLAUDE SUBAGENT_COST_GUARD_MODE=deny timeout 600 claude -p "$PROMPT" \
        --model "$MODEL" --output-format stream-json --verbose --include-hook-events \
        --strict-mcp-config --setting-sources project --plugin-dir "$PDIR" \
        --permission-mode bypassPermissions --no-session-persistence \
        --max-budget-usd 0.60 ) > "$out.part" 2>"$out.err"
    if grep -q '"type":"result"' "$out.part"; then mv "$out.part" "$out"; echo "done $arm-$n"
    else echo "FAIL $arm-$n — no result record, see $out.err"; fi
  done
done

set -- "$WORK"/out/*.jsonl
[ -e "$1" ] || { echo "no completed runs in $WORK/out"; exit 1; }
python3 - "$@" <<'PY'
import json, sys, os

def blocks(path):
    for line in open(path, encoding='utf-8', errors='ignore'):
        try: yield json.loads(line)
        except ValueError: pass

for path in sorted(sys.argv[1:]):
    hooks, tools, results = [], [], []
    for d in blocks(path):
        if d.get('subtype') == 'hook_started' and 'SessionStart' in str(d.get('hook_name')):
            hooks.append(d['hook_name'])
        m = d.get('message') or {}
        for b in m.get('content') or []:
            if not isinstance(b, dict): continue
            if b.get('type') == 'tool_use': tools.append((b.get('name'), b.get('input') or {}))
            elif b.get('type') == 'tool_result':
                t = b.get('content')
                if isinstance(t, list): t = ' '.join(x.get('text','') for x in t if isinstance(x, dict))
                results.append(str(t))
    agents = [i for n, i in tools if n == 'Agent']
    print('=' * 74)
    print(os.path.basename(path))
    print('  SessionStart fired :', hooks or 'none')
    print('  tools              :', ', '.join(n for n, _ in tools))
    print('  skills             :', [i.get('skill') for n, i in tools if n == 'Skill'] or 'none')
    print('  gate denials       :', sum('no `model`' in r for r in results))
    if agents:
        print('  first Agent        : type=%r model=%r' % (agents[0].get('subagent_type'), agents[0].get('model')))
        if len(agents) > 1:
            print('  later Agent calls  :', [(a.get('subagent_type'), a.get('model')) for a in agents[1:]])
    else:
        print('  first Agent        : NONE')
    seen = False
    for d in blocks(path):
        m = d.get('message') or {}
        if m.get('role') != 'assistant': continue
        for b in m.get('content') or []:
            if not isinstance(b, dict): continue
            if b.get('type') == 'tool_use' and b.get('name') == 'Agent': seen = True
            elif b.get('type') == 'text' and b.get('text','').strip() and not seen:
                t = b['text'].strip()
                if t.startswith('Base directory for this skill:'): continue
                for ln in t.splitlines(): print('    | ' + ln)
        if seen: break
PY
