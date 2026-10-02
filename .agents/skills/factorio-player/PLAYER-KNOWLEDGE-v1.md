# Player knowledge v1

A short Factorio intro for both roles. The mechanics are game rules as the
tools report them. The hints are starting points that newer structured evidence
may override. Neither is a build order.

## Boundary

Durable player knowledge, in this file and in the run notebook, may hold only
facts learned through honest in-game play and structured Factorio Codex
observations: recipes and recipe relationships, calculations from in-game
values, repeatable operations, and Codex-authored relative layouts. Never store
map coordinates, tutorials, external blueprint strings, online build sequences,
or seed facts. No world position, landmark, route, or coordinate pair belongs in
this file. Revalidate a retained lesson against current structured state before
using it.

## Mechanics

- Burner machines (burner drills, stone furnaces, boilers, burner inserters)
  burn items from a fuel slot. A burner drill burns one coal in about 27 s, and
  a stone furnace in about 45 s at full duty, longer while it waits on input. A
  source that only refuels other burners cycles at their burn rate.
- A drill drops its output at the position ahead of it: an entity it feeds
  directly, or the ground or a belt. A furnace chooses its recipe from the
  inserted input, and its full output slot stops it.
- An inserter moves items from its pickup position to its drop position. It
  waits for items and for space. An inserter waiting for space over a stocked
  slot (such as a fuel-return inserter over a full fuel slot) is normal
  backpressure; mining or rotating it breaks a working loop.
- A belt carries two lanes. A run that ends without a consumer is a dead end.
- Steam power: an offshore pump supplies water, a fuelled boiler makes steam,
  and one boiler supplies about two steam engines. Poles join consumers into an
  electric network; an unpowered machine stops.
- Assemblers make their set recipe from inserted ingredients. Labs consume
  science packs only for the active research; with none active they sit idle.
- A status is one sample. `waiting_for_space_in_destination` is zero
  utilization at that sample only, even if the machine produced earlier, so
  judge a segment by downstream output over a window.
- Mining yields per cycle, not per request. Hand-crafting queues on the
  character, and a removal is refused while crafting is queued.

## Hints

- **Input before output.** Compounding input growth comes first: raw
  extraction, smelting, and fuel or power capacity stay ahead of demand, and
  early resources and new plates are reinvested into more of them. Science or
  other output pays when research unlocks a growth step or input has headroom.
  Hand-crafting science while raw input is the bottleneck starves expansion.
  Input rate (ore and plates per minute) is the primary measure.
- **Fuel first.** A burner source without a non-character fuel return is the
  bottleneck: build its fuel loop or move to powered extraction before scaling
  it. On a belt shared by a burner's fuel takeoff and a surplus takeoff, the
  fuel takeoff sits upstream so surplus never starves the fuel loop.
- **Starter fuel.** Give bootstrap burners two or three fuel items when a fuel
  return exists, so the validation window exercises the return.
  `fuel_return_beyond_window` means that stock was too large.
- **Packet size.** Size fuel and input packets from the observed rate times the
  time until the body returns. Avoid token packets and oversized idle
  stockpiles. Never hand-insert more than a few crafts of input before a
  validation window.
- **One terminal buffer.** Each segment ends in a consumer or at most one
  terminal buffer. Fix full or blocked output at its cause (empty the buffer as
  a named bridge, or extend the segment to a consumer), never by adding a chest
  or sink.
- **Validation timing.** Cover several processor cycles and one fuel item per
  burner. Queue the validation after a `wait_for_item` on the segment's terminal
  output, once bootstrap insertions are done and the segment produces.
- **Two strikes.** The same structural blocker failing a segment twice means
  redesign from fresh reads, not a third repair.
- **Removal recipe.** Remove the entity's feeding inserter first (extracting
  that inserter's fuel). Put an extraction naming every item the entity may
  hold, with counts at or above its capacity, ahead of the removal. A
  replacement on the removed tiles goes in a successor package, because
  `can_place` still sees the standing entity. Never remove a node with recent
  accepted output before its replacement proves output.
- **Service cycles.** A second hand batch of the same item is a service cycle;
  connected production for it usually pays back before a third.
- **Linear runs.** Build belt, pipe, and pole runs with `connect_entities`
  rather than one walk and placement per entity.
- **Scaling.** Count capacity only after output is observed at its
  destination. Validate existing output before scaling upstream input, fuel, or
  machine count. Prefer compact, connectable production and short shared
  corridors over disconnected islands. A destination type or direction that
  failed once falsifies that arrangement, not every arrangement.

## Learning

Learn through a state-driven loop: observe authoritative state, identify the
bottleneck, form a falsifiable hypothesis, predict a measurable effect, choose a
safe action, compare predicted and actual results. Astra retains, revises, or
discards the lesson in the notebook with provenance and uncertainty; the pilot
reports a falsified lesson instead of writing it. When an
exact factor is unobservable, run only a bounded experiment with a safe bound
and a numeric stop. Never turn a lesson into an opening script, elapsed-time
milestone, fixed build order, named route, or prescriptive progression
sequence.
