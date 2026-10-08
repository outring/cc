#!/usr/bin/env bash
# Measures real dispatch behaviour across session transcripts.
# Knobs: dev/README.md. Figures: dev/evidence.md.
set -uo pipefail
SINCE_EPOCH="${1:-1786492800}"   # default: 2026-08-12T00:00Z
UNTIL_EPOCH="${2:-9999999999}"   # default: no upper bound
cd "${CLAUDE_PROJECTS:-$HOME/.claude/projects}" || exit 1

python3 - "$SINCE_EPOCH" "$UNTIL_EPOCH" <<'PY'
import json, glob, os, re, sys, collections, datetime

since, until = float(sys.argv[1]), float(sys.argv[2])
pairs, models, wf = collections.Counter(), collections.Counter(), collections.Counter()
# A denial is only counted when an errored tool_result carrying the gate's text
# resolves to a tool_use id that the gate would actually have denied. Matching
# the text alone would count any failed command that merely prints it — a grep
# over the hook source, say — and make a disabled gate look effective.
# Correlation records are collected across the whole scan, not just the window:
# a dispatch inside it can be denied by a result landing just outside, and
# window-filtering both sides would drop the pair. A matched denial is attributed
# to the window holding the *dispatch*, so the total is an outcome of that
# window's dispatches rather than an artefact of where the pair straddles.
gate_worthy = {}     # tool_use_id -> (kind, dispatch timestamp)
denial_hits = {}     # tool_use_id -> result timestamp
GATEABLE = {'Explore', 'general-purpose', 'Plan', 'claude', '(none)'}
DENIAL_MARKS = ('this Agent call sets no',
                'this workflow script calls agent() but sets no')
# The hook's own workflow checks: whitespace allowed, model 'inherit' is an omission.
WF_AGENT = re.compile(r'agent\s*\(')
WF_MODEL = re.compile(r'model\s*:')
WF_INHERIT = re.compile(r'''model\s*:\s*['"]inherit['"]''')
WF_EFFORT = re.compile(r'effort\s*:')
WF_MODEL_LIT = re.compile(r'''model\s*:\s*['"](haiku|sonnet|opus|fable)['"]''')
WF_EFFORT_LIT = re.compile(r'''effort\s*:\s*['"](low|medium|high|xhigh|max)['"]''')


def when(rec):
    """Event time as an epoch, or None. Records are bucketed by their own
    timestamp, not the file's mtime: a resumed session rewrites mtime and would
    otherwise silently leave a window that has already been quoted."""
    ts = rec.get('timestamp')
    if not isinstance(ts, str):
        return None
    try:
        return datetime.datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


for p in glob.glob('*/*.jsonl'):
    try:
        # Safe prefilter only: a file last written before `since` cannot hold an
        # event at or after it. No upper bound here — a file touched after
        # `until` may still hold events from inside the window.
        if os.path.getmtime(p) < since:
            continue
        fh = open(p, encoding='utf-8', errors='ignore')
    except OSError:
        continue
    with fh:
        for line in fh:
            # Denials arrive as tool_result blocks on user records, which carry
            # no "tool_use" marker — admit both or every denial is skipped.
            if '"tool_use"' not in line and '"tool_result"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = when(d)
            if t is None:
                continue
            in_window = since <= t < until
            content = ((d.get('message') or {}).get('content'))
            if not isinstance(content, list):
                continue
            for blk in content:
                if not isinstance(blk, dict):
                    continue
                if blk.get('type') == 'tool_result':
                    body = blk.get('content')
                    if isinstance(body, list):
                        body = ' '.join(x.get('text', '') for x in body
                                        if isinstance(x, dict))
                    if (blk.get('is_error') and isinstance(body, str)
                            and any(m in body for m in DENIAL_MARKS)):
                        denial_hits[blk.get('tool_use_id')] = t
                    continue
                if blk.get('type') != 'tool_use':
                    continue
                i = blk.get('input') or {}
                if blk.get('name') == 'Agent':
                    m = i.get('model') or '(unset)'
                    if m in ('(unset)', 'inherit') and i.get('subagent_type', '(none)') in GATEABLE:
                        gate_worthy[blk.get('id')] = ('Agent', t)
                    if not in_window:
                        continue
                    pairs[(i.get('subagent_type', '(none)'), m)] += 1
                    models[m] += 1
                elif blk.get('name') == 'Workflow':
                    s = i.get('script') or ''
                    if WF_AGENT.search(s) and not (WF_MODEL.search(WF_INHERIT.sub('', s))
                                                   and WF_EFFORT.search(s)):
                        gate_worthy[blk.get('id')] = ('Workflow', t)
                    if not in_window:
                        continue
                    for tier in WF_MODEL_LIT.findall(s):
                        wf['model:' + tier] += 1
                    for eff in WF_EFFORT_LIT.findall(s):
                        wf['effort:' + eff] += 1

total = sum(pairs.values())
denials = collections.Counter(
    gate_worthy[i][0] for i in denial_hits
    if i in gate_worthy and since <= gate_worthy[i][1] < until)
uncorrelated = sum(1 for i, ts in denial_hits.items()
                   if i not in gate_worthy and since <= ts < until)
gateable_unset = sum(v for (t, m), v in pairs.items() if m == '(unset)' and t in GATEABLE)
exempt_unset = models['(unset)'] - gateable_unset


def pc(n):
    return '%5.1f%%' % (100.0 * n / total) if total else '    -'


print('Agent calls total       : %d' % total)
if total:
    print('  no explicit model     : %d (%s)' % (models['(unset)'], pc(models['(unset)']).strip()))
    print('    gateable (would deny): %d (%s)' % (gateable_unset, pc(gateable_unset).strip()))
    print('    exempt (named)       : %d (%s)' % (exempt_unset, pc(exempt_unset).strip()))
    print('  by model:')
    for k in ('haiku', 'sonnet', 'opus', 'fable'):
        print('    %-10s %5d  %s' % (k, models[k], pc(models[k])))
    for k in sorted(models):
        if k not in ('haiku', 'sonnet', 'opus', 'fable', '(unset)'):
            print('    %-10s %5d  %s' % (k, models[k], pc(models[k])))
    print('    %-10s %5d  %s' % ('(unset)', models['(unset)'], pc(models['(unset)'])))
print('Gate denials observed   : %d  (Agent %d, Workflow %d)'
      % (sum(denials.values()), denials['Agent'], denials['Workflow']))
if uncorrelated:
    print('  unmatched denial text : %d (ignored — not a gated dispatch)'
          % uncorrelated)
print('  by (subagent_type, model):')
for k, v in pairs.most_common():
    print('    %5d  %s' % (v, k))
print('Workflow agent() opts:')
for k, v in sorted(wf.items()):
    if v:
        print('    %5d  %s' % (v, k))
PY
