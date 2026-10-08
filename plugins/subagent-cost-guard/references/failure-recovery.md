# Failure recovery

Author every workflow so a failing agent never loses data.

* **No silent drops:** `agent()` resolves to `null` on failure. Never bare
  `.filter(Boolean)` — pair every result with its input (`{item, result}`) so
  failed items stay identifiable and re-runnable
* **Return partial results always:** accumulate into a results array; wrap
  loops and budget-capped calls in try/catch so the script returns
  `{done, failed}` instead of throwing away completed work
* **Failed-item manifest:** return each failed item with its input, stage, and
  reason. `log()` every drop — silent truncation reads as full coverage
* **Keep the handle:** after launching a workflow, keep the `runId` and
  `scriptPath`; report them when any agent failed
* **Resume-safe prompts:** keep `agent()` prompts and opts deterministic (no
  timestamps, no randomness) so resume cache hits

## Recovering a failed run

1. Read `<transcriptDir>/journal.jsonl` — it records every agent's actual
   return value. Do this before re-running or declaring loss
2. `Workflow({scriptPath, resumeFromRunId})` — unchanged `agent()` calls
   replay from cache
