# Evidence

## Dispatches before and after the gate

`measure-baseline.sh` over one user's transcripts. Rules moved into
`CLAUDE.md` in late August; the gate shipped on 1 Sep 2026.

| `Agent` calls | to 12 Aug | 12 Aug – 1 Sep | 1 Sep – 8 Sep |
|---|---|---|---|
| Total | 946 | 234 | 146 |
| `haiku` | 13 (1.4%) | 7 (3.0%) | 22 (15.1%) |
| `sonnet` | 11 (1.2%) | 137 (58.5%) | 97 (66.4%) |
| `opus` | 5 (0.5%) | 27 (11.5%) | 12 (8.2%) |
| No `model` | 917 (96.9%) | 63 (26.9%) | 15 (10.3%) |
| …gateable | 861 (91.0%) | 62 (26.5%) | 6 (4.1%) |
| …exempt (named agents) | 56 (5.9%) | 1 (0.4%) | 9 (6.2%) |
| Gate denials observed | 0 | 0 | 11 (5 `Agent`, 6 `Workflow`) |

```sh
bash dev/measure-baseline.sh 1          1786492800
bash dev/measure-baseline.sh 1786492800 1788217200
bash dev/measure-baseline.sh 1788217200 1788890400
```

* The rules alone took gateable from 91.0% to 26.5%. The gate added 26.5% →
  4.1%
* 5 of the 6 post-gate gateable calls pair by `tool_use_id` to a denial
* Workflow `agent()` model literals: `opus` share rose 35% → 49%. The gate
  only requires one tier per script, so workflow spend stays open

## Placement: `CLAUDE.md` versus `SessionStart`

Same rule text, 5 reps each at `opus`. Task: a mechanical sweep the user asks
to delegate. Reproduce: `ab-injection.sh`.

| Arm | Rules in | `model` set | `haiku` | skill read first | denials |
|---|---|---|---|---|---|
| A | `CLAUDE.md` | 5/5 | 5/5 | 5/5 | 0 |
| B | `SessionStart` hook | 5/5 | 5/5 | 5/5 | 0 |
| C | nowhere | 1/5 | 1/5 | 1/5 | 4 |

The hook ties `CLAUDE.md`. Without either, the skill description and the gate
are not enough.

## Skill `description` wording

4 arms × 5 reps.

| Arm | named skill | chose `haiku` |
|---|---|---|
| no description | 0/5 | 1/5 |
| older wording | 5/5 | 4/5 |
| triggers only after a failed dispatch | 2/5 | 1/5 |
| shipped | 5/5 | 5/5 |

The tier table is needed before dispatch, so triggers must fire before it.

## `Explore` row has no condition

| `Explore` row | `model` chosen |
|---|---|
| `haiku` for known-shape sweeps, else `sonnet` | `sonnet` 5/5 |
| `haiku`, unconditional (shipped) | `haiku` 5/5 |
| row deleted | `haiku` 5/5 |

The model takes any upward escape clause, so no row carries one.

## Tier table stays out of the injection

A summary in context that looks sufficient stops the skill being read — arm C
above. `run_tests.sh` asserts the injection holds no tier table.

## Sonnet-first tiers

Prices on 3 Oct 2026, Claude Code `2.1.285`; refresh with `alias-check.sh`.

| Alias | Model | Input / output per MTok |
|---|---|---|
| `haiku` | `claude-haiku-4-5` | $1 / $5 |
| `sonnet` | `claude-sonnet-5-5` | $2 / $10 |
| `opus` | `claude-opus-5-5` | $4 / $20 |
| `fable` | `claude-fable-5-1` | $10 / $50 |

Sonnet 5.5 is within three points of Opus 5.5 on six of eight published
benchmarks, so cross-file root cause moved from `opus` to `sonnet` at `high`.

`ab-micro.sh`, 5 reps at `sonnet`, $2.16. Prompt 2 adds pressure: "this needs
careful cross-file reasoning".

| Arm | Prompt | `sonnet` | `opus` |
|---|---|---|---|
| 0.3.0 | plain | 5/5 | 0/5 |
| 0.3.0 | pressure | 0/5 | 5/5 |
| 0.4.0 | plain | 5/5 | 0/5 |
| 0.4.0 | pressure | 5/5 | 0/5 |

0.3.0 took its "`opus` for cross-file reasoning" clause in every pressure rep.
