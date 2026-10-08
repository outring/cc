# subagent-cost-guard

Blocks an `Agent` or `Workflow` dispatch that would silently inherit an `opus`
or `fable` model until it names a model tier and, for workflows, an effort.

```
/plugin marketplace add outring/cc
/plugin install subagent-cost-guard@outring-cc
```

Requires `jq`.

> **Blocks by default.** An untiered `Agent` call on a generic type is denied.
> The denial names the tiers.

## Parts

* `hooks/agent-tier-gate.sh` — `PreToolUse` gate on `Agent` and `Workflow`
* `hooks/session-context.md` — dispatch rules injected at `SessionStart`
* `skills/orchestrating-agents` — agent-type and model/effort tier tables
* `references/failure-recovery.md` — loaded by the skill on demand

## Configuration

`gate_mode`: `deny` (default), `warn` (stderr note only), `off` (no gate, no
session rules). Any other value means `deny`.

| Route | Scope |
|---|---|
| `SUBAGENT_COST_GUARD_MODE=off claude` | One session, highest precedence |
| `/plugin` → configure `subagent-cost-guard` | Persistent |

Or in `~/.claude/settings.json`:

```json
{
  "pluginConfigs": {
    "subagent-cost-guard@outring-cc": { "options": { "gate_mode": "warn" } }
  }
}
```

`warn` does not reach the model: `PreToolUse` has no `additionalContext`.

## Denied

A dispatch with `model` unset or `inherit` whose inherited model is `opus`,
`fable` or unreadable:

* `Agent` on `Explore`, `general-purpose`, `Plan`, `claude` or no type
* `Workflow` inline script that calls `agent()` with no `model:` anywhere, or
  no `effort:` anywhere. One occurrence clears the whole script: the gate
  catches zero tiering, not partial

Inherited model: `CLAUDE_CODE_SUBAGENT_MODEL`, else the last assistant model in
the session transcript.

## Never denied

* An explicit `model` other than `inherit` — alias, `[1m]` variant or full ID
* An inherited `haiku` or `sonnet`
* `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` set
* `subagent_type: "fork"`, and named or plugin agents (`feature-dev:*`)
* Workflow resume by `scriptPath` or `name`
* Bad input, missing `jq`, parse error — the hook fails open

## Effect

On the author's transcripts from 1 Sep to 8 Oct 2026, the gate denied 46 of
the 47 untiered `Agent` calls it targets. From before the gate to the 4 days
to 8 Oct, `haiku` rose from 3.0% to 30.0% of `Agent` calls and `opus` fell
from 11.5% to 6.0%. Data and A/B results: [`dev/evidence.md`](dev/evidence.md).

Do not edit the skill `description` without re-running its A/B.
Development: [`dev/README.md`](dev/README.md).
