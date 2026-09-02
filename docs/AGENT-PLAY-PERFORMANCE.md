# Agent play performance

Release 0.8.0 reduces reasoning round trips while preserving one physical
Codex body, one task lane, and honest Factorio mechanics.

## Recorded baseline and operating model

The accepted one-shot live baseline required **22 MCP calls** for the initial
mine/craft/place/fuel/inspect milestone. This is the comparison baseline, not a
claim that the 0.8.0 path has already been live-validated.

Use one persistent Sol-medium strategist and one persistent Luna-low pilot.
Sol batches reads and sends bounded milestones. Luna is the sole ordinary
action writer and executes knowable dependent actions with `run_plan`. This
removes model-thinking idle time; it does not accelerate walking, mining,
crafting, or any other game tick.

For each live benchmark, record the release SHA, milestone, MCP call count,
wall time, Factorio tick delta, completed/failed plan steps, final position and
inventory, and any `MCP_GAP`. Compare the same fresh-save milestone against the
22-call baseline. Do not report a speedup until the parent completes the
post-publication live run.

## Durable discovery rule

Prefer an existing batched read or exact positional action. A repeatable task
should become a bounded `run_plan` input, not new Lua orchestration. If a tool
lacks state required for a correct decision, stop with `MCP_GAP`: objective,
missing field, current tool, why it is needed, and the smallest structured
addition. Add durable MCP state only after that concrete gap is reproduced;
never infer it from screenshots, by-name search, or hidden global state.

## Research patterns

- [Voyager](https://arxiv.org/abs/2305.16291): adopt reusable bounded skills
  and feedback after execution. Reject open-ended self-directed curricula,
  generated game code, and a second model loop inside the product.
- [Mineflayer Pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder):
  adopt explicit goals and reusable physical pathfinding. Reject teleporting,
  direct world mutation, and a parallel movement implementation.
- [LLM-PySC2](https://arxiv.org/abs/2411.05348): adopt compact textual
  observations, structured actions, and strategist/pilot separation. Reject
  image input, multi-body control, and population-scaled agent orchestration.
- [Factorio Learning Environment](https://arxiv.org/abs/2503.09617): adopt
  long-horizon benchmark discipline and honest failure reporting. Reject its
  code-synthesis REPL, privileged game access, free resources, and benchmark
  machinery as runtime dependencies.

The retained design is deliberately smaller: MCP synchronously sequences
existing tools, Lua continues to own only physical tasks, and every terminal
plan path attempts one compact local observation.
