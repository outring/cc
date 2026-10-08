# dev

Not loaded at runtime. Tools and evidence behind the plugin's claims.

| File | Purpose |
|---|---|
| `run_tests.sh` | Hook self-check. Hermetic, runs in CI |
| `test_measure.sh` | `measure-baseline.sh` self-check. Hermetic, runs in CI |
| `measure-baseline.sh` | Counts real dispatches in session transcripts |
| `alias-check.sh` | Alias resolution on this build, env pins, models subagents ran on |
| `ab-injection.sh` | Re-runs the rule-placement A/B. About $9 |
| `ab-micro.sh` | `origin/main` plugin against the working tree. About $2 |
| `evidence.md` | Measurements and A/B results |

```sh
bash dev/run_tests.sh
bash dev/test_measure.sh
bash dev/alias-check.sh [days]
```

The A/B scripts spend real money. They run `claude -p` with
`bypassPermissions` against a fresh `mktemp -d` fixture. Manual only. Read
every rep by hand and record the result in `evidence.md`.

## Measuring

```sh
bash dev/measure-baseline.sh [since] [until]
```

| Knob | Default |
|---|---|
| `since`, Unix epoch | `1786492800` (2026-08-12T00:00Z) |
| `until`, Unix epoch | now |
| `CLAUDE_PROJECTS` | `~/.claude/projects` |

Records are bucketed by event timestamp, so a closed window gives stable
figures. Check every epoch: `1755000000` is 2025, not 2026.

A denied dispatch still appears as a `tool_use` with no `model`, because
`PreToolUse` fires after the model emits the call. The `gateable` count
includes those. For what the gate did, read `Gate denials observed`.
