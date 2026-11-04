---
name: orchestrating-agents
description: Use when about to spawn a subagent with the Agent tool, fan out parallel agents, or author or resume a Workflow script, when choosing which agent type, model, or effort a stage runs at, or when a run's agents failed, returned null, or were skipped.
---

# Orchestrating Agents

## Overview

Cheap models fan out, expensive models verify and synthesise — never the reverse. Every fan-out must be recoverable: a failing agent loses nothing.

## Every dispatch names its tier

* A dispatch with no stated tier is unfinished
* Name the agent type, the model and the effort on the same line as the reason, before the prompt
* `Explore` at `haiku` — mechanical sweep over known-shape files
* Omitting `model`, or `model: inherit`, inherits `CLAUDE_CODE_SUBAGENT_MODEL` if set, else the session model — on most sessions `opus` or `fable`
* Use the aliases `haiku` / `sonnet` / `opus` / `fable`; each tracks the newest model of its tier. A full ID pins a version

## Parameter shape

* `Agent` and workflow `agent()` both take `model` and `effort`
* The `Agent` tool's `effort` description waits for an instruction that asks for it. This skill is that instruction: set both on every generic dispatch
* `subagent_type: "fork"` ignores both — pass neither
* Named or plugin agents: omit both

## Agent type

| Task shape | `subagent_type` | model | effort |
|---|---|---|---|
| Broad read-only sweep, locate code, "where is X" | `Explore` | `haiku`. Escalate to `sonnet` only after a `haiku` sweep has come back empty | `low`; `medium` once escalated to `sonnet` |
| Multi-step work needing edits or shell | `general-purpose` | `sonnet` | `medium` |
| Design an approach, weigh trade-offs | `Plan` | `opus` | `high` |
| Needs this conversation's full context | `fork` | inherits — `model` is ignored | omit |
| Named or plugin agent (`feature-dev:*`, `code-review`, …) | that type | omit — the agent definition sets it | omit |

* `Explore` reads excerpts, not whole files — it locates code, it does not review or audit it

## Model and effort tiers

The default tier is `sonnet`. `haiku` is for mechanical work and `opus` for judgement — not for doing the work twice as well. Set `model` and `effort` per `Agent` call and per `agent()` call, not per workflow.

| Stage | model | effort | Use for |
|---|---|---|---|
| Mechanical | `haiku` | `low` | grep/glob sweeps, file inventories, log scraping, renames, formatting, structured extraction |
| Standard | `sonnet` | `medium` | per-file review, tests, docs, bug fixes, scoped multi-file edits, per-item transforms |
| Deep | `sonnet` | `high` | cross-file refactors, root-cause analysis, synthesis of one stage's results |
| Judgement | `opus` | `high` | adversarial verify, final synthesis across agents, architecture trade-offs |
| Last resort | `fable` | `xhigh` | only after `opus` has failed the same task twice |

* One `opus` verifier or synthesiser behind `sonnet` workers — never `opus` workers
* Cap concurrent `opus`/`fable` agents at 4; `haiku`/`sonnet` may use the full pool
* `max` effort at most once per workflow, and only when correctness outranks cost
* Haiku has the smallest context — never give it a whole-repo or whole-transcript task
* Ultracode raises breadth, not tier: more agents at the same tiers, not everything on `opus`

## Script before agents

Mechanical or deterministic work — counting, filtering, dedup, formatting, renames, grep/glob sweeps — is one script run once (`Bash`, plain JS in a workflow, or Python). Never one agent per item. Reach for the mechanical tier only when the step needs judgement a script cannot express.

## Common mistakes

| Mistake | Fix |
|---|---|
| No `model` on the call, or `model: inherit` | Name the tier; what is inherited is usually the expensive one |
| `opus` because the task "feels hard" or spans files | `sonnet` at `high`. `opus` verifies or synthesises; it does not work harder |
| `general-purpose` for a read-only search | `Explore` |
| `model` or `effort` passed to a `fork` | Drop it — forks always inherit |
| `model` forced onto a named plugin agent | Omit it — its definition already chose |
| The Workflow docstring's "default to omitting `model` … almost always correct" | That inherits the session model. Set `model` and `effort` on every `agent()` |
| No `effort` on an `Agent` call or a workflow `agent()` | On the session model it inherits the session effort; on another model it gets that model's saved or default level (`medium` on Opus, Sonnet and Haiku 5.5). The gate denies it on an opus or fable session |
| `sonnet` at `low` for a subagent | `medium` or above — at `low` it may skip verification or stop to ask, and a subagent cannot ask |
| A dated model ID (`claude-haiku-4-5-20251001`) | The alias; it tracks the tier's current model |
| One agent per list item for a mechanical sweep | One script, run once |
| `.filter(Boolean)` on agent results | Pair result with input; keep failures identifiable |
| Re-running a whole workflow after a partial failure | Read the journal, then resume from `runId` |
| Timestamps or randomness in an agent prompt | Breaks the resume cache — pass them via `args` |

## When an agent fails

An agent returned `null`, a fan-out dropped items, or a workflow died partway:
`${CLAUDE_PLUGIN_ROOT}/references/failure-recovery.md`.
