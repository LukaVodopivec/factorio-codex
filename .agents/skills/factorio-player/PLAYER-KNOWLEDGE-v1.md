# Player knowledge v1

A short Factorio intro for both roles. The mechanics are game rules as the
tools report them. The hints are starting points that newer structured evidence
may override. Neither is a build order.

## Boundary

Facts from honest in-game play and Codex observations (recipes, calculations
from in-game values, repeatable operations, Codex-authored relative layouts),
plus researched principles and ratios written in this repository's own words. Never store map
coordinates, tutorials, external blueprint strings, copied layouts, online
build sequences, or seed facts here. The run notebook holds this run's
observations, exact positions included; nothing carries over to another run.

## Mechanics

- Burner machines (burner drills, stone furnaces, boilers, burner inserters)
  burn items from a fuel slot. A burner drill burns one coal in about 27 s and
  a stone furnace in about 45 s at full duty.
- A drill drops its output just ahead of it: into an entity there, onto a
  belt, or on the ground. A furnace picks its recipe from its input, and a full
  output slot stops it.
- An inserter moves items from its pickup side to its drop side. It waits for
  items and for space; waiting for space is normal backpressure.
- Steam power: an offshore pump supplies water, a fuelled boiler makes steam,
  and one boiler supplies two steam engines. Poles join machines into an
  electric network; an unpowered machine stops.
- Labs consume science packs only for the active research. Hand-crafting
  takes real time.

## Hints

- **Opening.** Plates gate every machine, and fuel pays only when it feeds
  something that makes progress. Choose what to automate from what you carry
  and the patches in view.
- **Supply before demand.** Raw extraction, smelting, and fuel or power
  capacity stay ahead of what the factory consumes. Ore or plates piling up
  in chests should feed more machines that turn them into intermediates and
  science; a pile is not progress.
- **Fuel.** A burner line needs a fuel feed that is not the body. On a belt
  shared by a fuel takeoff and a surplus takeoff, the fuel takeoff sits
  upstream so surplus never starves the fuel loop.
- **Whole blocks.** Build a mining row, a smelting column, or an assembler row
  at once rather than one machine at a time; a design that worked is cheapest
  to repeat at a new site as this run's blueprint.
- **Outlets.** Every line ends in a consumer or a chest with space. Fix a full
  output at its cause: use the stock, add a consumer, or extend the line.
- **Use your stock.** Chests, furnace outputs, and belts are the first source
  for building and crafting. Machine-made parts (gears, cable, circuits,
  belts, inserters) come from the machines that make them.
- **Hand work.** Feeding a running machine by hand again and again means it
  needs a permanent feed.
- **Two strikes.** The same failure twice at one site means a new design, not
  a third repair.

## Speed hints

Principles and ratios from fast play, in our own words. They are overridable
hints, never a build or technology order: measured state wins.

- **Compounding.** A producer placed early pays back for the whole run, and
  parts left in the inventory are waste; place them where the base plan has
  room for them.
- **Sizing.** Size a line from the rate you need: `production_requirements`
  with `per_minute` gives the machines, drills, fuel or power and belts.
- **Rates.** Electric drill 0.5 ore/s, burner drill 0.25 ore/s, stone furnace
  0.3125 plates/s, yellow belt 15 items/s.
- **Ratios.** 5 electric drills feed 8 stone furnaces; a full yellow belt is
  30 drills and 48 furnaces. 5 red science assemblers per 6 green (size iron
  for green). 3 cable assemblers per 2 circuit assemblers.
- **Power.** 1 boiler (1.8 MW) runs 2 steam engines (0.9 MW each). A shortage
  (`power` satisfaction below 100%) slows every machine on the network, so
  new consumers add little until generation catches up. Once researched, solar panels
  with accumulators are an option that needs no fuel; `add_to_cover` sizes
  both.
- **Mall.** Assemblers that make belts, inserters, drills, poles, and pipes
  into chests (slot limit set at build time) save the body's crafting time.
  Filter inserters and filtered splitters sort mixed belts, such as Fulgora's
  scrap.
- **Water.** Landfill joins a site across water; Aquilo's ocean takes ice
  platform.
- **Research.** Choose research for what it unlocks at the current
  bottleneck. In 2.0 some technologies unlock by a trigger, not science:
  crafting iron plates, copper plates, a lab, or steel, and mining crude oil
  or uranium ore.
- **Space Age.** The win is a platform reaching the solar system edge. Choose
  each planet for what it unlocks toward that and the constraint it adds.
  Quality brings the edge no closer. Keep the first platforms minimal.

## Learning

Find the bottleneck, predict what a fix will do, act, and compare; keep,
revise, or drop the lesson in your notebook folder. Never turn a lesson into an
opening script, a timed milestone, a fixed build order, or a named route.
