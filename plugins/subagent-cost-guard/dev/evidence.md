# Evidence

## Dispatches by era

`measure-baseline.sh` over one user's transcripts.

1. Pre-routing, 1 Jun – 12 Aug: no model rules, no gate
2. Routing, 12 Aug – 1 Sep: rules in `CLAUDE.md`, no gate
3. Gating, 1 Sep – 4 Oct: rules and gate
4. Fixed gating + Sonnet 5.5, 4 – 8 Oct: 0.4.0 gate and sonnet-first tiers

| `Agent` calls that ran | 1. Pre-routing | 2. Routing | 3. Gating | 4. Fixed gating |
|---|---|---|---|---|
| Total | 898 | 234 | 333 | 50 |
| `haiku` | 13 (1.4%) | 7 (3.0%) | 73 (21.9%) | 15 (30.0%) |
| `sonnet` | 11 (1.2%) | 137 (58.6%) | 205 (61.6%) | 29 (58.0%) |
| `opus` | 5 (0.6%) | 27 (11.5%) | 32 (9.6%) | 3 (6.0%) |
| `fable` | 0 | 0 | 4 (1.2%) | 0 |
| Full model ID | 0 | 0 | 2 (0.6%) | 0 |
| No `model`, named agent | 49 (5.5%) | 1 (0.4%) | 16 (4.8%) | 3 (6.0%) |
| No `model`, generic type | 820 (91.3%) | 62 (26.5%) | 1 (0.3%) | 0 |
| Denied, did not run | 0 | 0 | 46 `Agent`, 10 `Workflow` | 0 |

```sh
bash dev/measure-baseline.sh 1780272000 1786492800
bash dev/measure-baseline.sh 1786492800 1788217200
bash dev/measure-baseline.sh 1788217200 1791072000
bash dev/measure-baseline.sh 1791072000 1791417600
```

The script counts denied attempts as calls with no `model`. The table moves
them to their own row, so each column sums to 100%.

* Routing took untiered generic calls from 91.3% to 26.5%. Gating took them
  to 1 call and denied the other 46
* `haiku` 3.0% → 21.9% → 30.0%; `opus` 11.5% → 9.6% → 6.0%. Era 4 is 4 days
* Workflow `agent()` model literals, `opus` share by era: 57%, 35%, 50%, and
  1 of 2. The gate requires one tier per script, so workflow spend stays open

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

Live use does not reach the 5/5. `Explore` calls that name a model:

| Era | `haiku` | `sonnet` | `opus` |
|---|---|---|---|
| 3. Gating | 68 (34.2%) | 127 (63.8%) | 4 (2.0%) |
| 4. Fixed gating | 14 (58.3%) | 10 (41.7%) | 0 |

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

Live `general-purpose` calls that name a model, full IDs counted with their
tier:

| Era | `haiku` | `sonnet` | `opus` | `fable` |
|---|---|---|---|---|
| 3. Gating | 5 (6.2%) | 66 (81.5%) | 6 (7.4%) | 4 (4.9%) |
| 4. Fixed gating | 1 (5.0%) | 19 (95.0%) | 0 | 0 |

`opus` or `fable` went from 10 of 81 calls to 0 of 20.
