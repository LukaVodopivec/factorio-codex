# Player knowledge v1

A short Factorio intro for both roles. The mechanics are game rules as the
tools report them. The hints are starting points that newer structured evidence
may override. Neither is a build order.

## Boundary

This file holds facts learned through honest in-game play and structured
Factorio Codex observations (recipes and recipe relationships, calculations
from in-game values, repeatable operations, and Codex-authored relative
layouts), plus researched principles and ratios written in this repository's
own words. Never store map coordinates, tutorials, external blueprint strings,
copied layouts, online build sequences, or seed facts here. No world position,
landmark, route, or coordinate pair belongs in this file. The run notebook
records anything observed in its run, exact positions, maps, and
infrastructure inventories included; nothing carries over to another run.
Revalidate a retained lesson against current structured state before using it.

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
  Input rate (ore and plates per minute) is the primary measure. Flat input
  while plates pile up in buffers means those plates should fund more
  extraction and smelting; a proven Codex-authored layout reused at a new
  anchor is the cheapest next copy.
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
  terminal buffer. Fix full or blocked output at its cause (build with the
  buffer's stock, unload surplus into an existing chest or line, or extend the
  segment to a consumer), never by improvising a chest or sink outside a
  package. A full buffer of
  construction items is the intended stop for that line.
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
- **Use your stock.** Chests, furnace outputs, and belts are the first source
  for building and crafting (`stockpiles` names the holders). Leave a
  component alone only while its validation window runs; a later take from a
  furnace or machine inside a proven component just leaves a stale proof that
  the next validation renews. Hand-mine only
  what no drill of yours produces: trees, rocks, a resource with no drill yet.
  Take gears, cable, circuits, belts, and inserters from assemblers that make
  them. Carrying more than about two stacks of one resource is idle capital:
  deposit the surplus into the line or a chest.
- **Service cycles.** A second hand batch of the same item is a service cycle;
  connected production for it usually pays back before a third. Taking stock
  from a buffer to build with is not debt; only a repeated haul that keeps a
  machine running is. Carrying
  finished plates or hardware to a build site is capital, not service; only
  feeding a running machine's input or fuel is service.
- **Linear runs.** Build belt, pipe, and pole runs with `connect_entities`
  rather than one walk and placement per entity.
- **Scaling.** Count capacity only after output is observed at its
  destination. Validate existing output before scaling upstream input, fuel, or
  machine count. Prefer compact, connectable production and short shared
  corridors over disconnected islands. A destination type or direction that
  failed once falsifies that arrangement, not every arrangement.

## Speed hints

Principles and ratios from fast play, in our own words. They are overridable
hints, never a build or technology order: measured state wins.

- **Compounding.** A producer placed early pays back for the whole run, so
  place drills, furnaces, and assemblers as soon as their parts exist. Unused
  parts in the inventory are waste. Keep the hand-craft queue filled before
  walking, so travel time also crafts.
- **Opening scale.** About 10 iron, 6 copper, 16 coal, and 4 stone burner
  drills carry the opening; move to electric drills before bulk belts.
- **Rates.** Electric drill 0.5 ore/s, burner drill 0.25 ore/s, stone furnace
  0.3125 plates/s, yellow belt 15 items/s.
- **Ratios.** 5 electric drills feed 8 stone furnaces; a full yellow belt is
  30 drills and 48 furnaces. 5 red science assemblers per 6 green (size iron
  for green). 3 cable assemblers per 2 circuit assemblers.
- **Power.** 1 boiler (1.8 MW) runs 2 steam engines (0.9 MW each). A shortage
  slows every machine, so add a boiler and two engines whenever `power`
  satisfaction is below 100% or production sits at capacity.
- **Mall.** Right after red and green science run, automate belts, inserters,
  drills, poles, and pipes into capped chests and build from those chests.
  Unlock construction robots as early as research allows.
- **Research hint.** Automation, Logistics, Electronics, Fast inserter,
  Logistic science, Steel, Automation 2, Advanced material processing, Engine,
  Fluid handling, Oil, Plastics, Advanced circuits, Sulfur, Chemical science,
  robotics, production and utility science, the silo. In 2.0 some
  technologies unlock by a trigger, not science: crafting iron plates, copper
  plates, a lab, or steel, and mining crude oil or uranium ore.
- **Space Age.** The win is a platform reaching the solar system edge. A
  common fast planet order is Gleba, Fulgora, Vulcanus, Aquilo; evidence may
  choose another. Skip Quality. Keep the first platforms minimal.

## Learning

Learn through a state-driven loop: observe authoritative state, identify the
bottleneck, form a falsifiable hypothesis, predict a measurable effect, choose a
safe action, compare predicted and actual results. Each role retains, revises, or
discards the lesson in its own notebook folder with provenance and
uncertainty; the pilot also reports a falsified lesson. When an
exact factor is unobservable, run only a bounded experiment with a safe bound
and a numeric stop. Never turn a lesson into an opening script, elapsed-time
milestone, fixed build order, named route, or prescriptive progression
sequence.
