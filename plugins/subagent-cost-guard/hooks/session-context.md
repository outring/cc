## Orchestration

* Read `subagent-cost-guard:orchestrating-agents` before the first dispatch of a turn — it holds the agent-type and tier tables
* Every `Agent` call carries an explicit `model`. Every workflow `agent()` call carries an explicit `model` and `effort`
* Omitting `model`, or `model: inherit`, inherits `CLAUDE_CODE_SUBAGENT_MODEL` or the session model — usually the most expensive tier in use
* Exceptions: `subagent_type: "fork"` ignores `model`; named plugin agents keep their definition's model
* State the agent type, the model, and the reason on the same line as the dispatch
* Deterministic work (count, filter, dedup, rename) is one script, never one agent per item
* Cheap models fan out, expensive models synthesise — never the reverse
