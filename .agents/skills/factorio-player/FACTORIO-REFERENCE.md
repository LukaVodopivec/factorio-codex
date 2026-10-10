# Factorio reference

How Factorio's numbers fit together, in this repository's own words: no
layouts, coordinates, blueprint strings or build orders. Exact values come
from live reads (`describe_prototype`, `production_requirements`,
`factory_status`), which win over this file.

## Stock, flow and capacity

- **Stock** is what exists now (body, chests, machine slots, belts); **flow**
  is items per minute actually moving; **capacity** is the flow machines could
  reach if fed and emptied.
- Progress is flow that machines sustain on their own. Stock no machine uses
  is not progress; a machine that runs only while the body feeds it is not
  automated.
- Carried items are out of the factory: no machine uses them. A full body
  fails fetches, pickups and upkeep; a chest holds stock without body slots.

## Rates from game data

- **Crafting.** A machine finishes one recipe execution every
  `recipe time / crafting speed` seconds and yields the recipe's product
  amount. Machines needed for a target rate =
  `target per second × recipe time / (products per execution × crafting speed)`.
- **Smelting** is crafting in a furnace: the same formula with the furnace's
  crafting speed and the smelting recipe's time.
- **Mining.** A drill yields `mining speed / resource mining time` units per
  second (times the resource's product amount). Drills needed =
  `target per second × mining time / mining speed`.
- **Chains.** Work back from the item you want: each stage's demand is the
  next stage's ingredient amount times its executions. Round machine counts
  up; a fractional machine runs part-time. Size the slowest stage first.
- **Belts** carry a fixed number of items per second per tier (two lanes);
  one belt can carry many machines' output. **Inserters** move a few items
  per second each; a fast machine or a lab bank can need more than one.

## Energy

- **Burner machines** turn fuel energy into work at their full energy use.
  Fuel burned per minute = `energy use (watts) × 60 / effectivity / fuel
  value (joules)`. A machine with fuel in its slot but nothing to do burns
  nothing; one doing work drains its slot steadily.
- **Fuel slot space versus fuel validity.** A machine refuses a fuel item when
  the item is the wrong category (a stone furnace burns chemical fuel, not
  nutrients) or when the slot is already full; check which before retrying.
- **Burning versus reserve.** The fuel slot is the reserve; removing it
  stops the machine soon and never fixes a full output.
- **Electric machines** draw their energy use from the network. When demand
  exceeds generation, every machine on that network slows in proportion, so a
  power shortage looks like many slow machines, not one stopped one.
  Generation must be sized for the sum of the machines' energy use.

## Flow problems

- **Backpressure.** A full output stops a machine, and the stop propagates
  upstream: a full furnace output stops the furnace, its input stops filling,
  the drill feeding it fills and stops. Fix the most downstream full point
  first: give it a consumer, a chest with space, or a longer line.
- **Starvation** propagates downstream: a machine waiting for input waits
  because the stage before it is too slow, unfuelled or unconnected. Fix the
  most upstream empty point first.
- **Bottleneck.** In a chain, the stage with the lowest capacity relative to
  its demand limits everything after it. Adding machines elsewhere adds no
  flow. Find it by comparing each stage's actual rate with the rate the next
  stage asks for.
- **Fuel loops.** A burner line that mines its own fuel is only self-sufficient
  if its fuel flow exceeds what all its machines burn; otherwise it slowly
  runs dry and stops.

## Connections that make a line run

- Every producer needs a sink for its output that is not its own input: a
  consumer, a chest with space or a belt that leads somewhere. Two burner
  drills feeding each other only refuel each other; nothing leaves. An
  `output_full` machine is an unfinished connection, not a finished line.
- An inserter only works when it picks from the machine or belt that holds
  the item and drops into the one that needs it. Before building, confirm
  from the checks the tools report (`can_place` names what an inserter would
  pick from and drop onto) rather than from the intended direction.
- A belt run is a connection only when its last belt faces the consumer or
  the inserter that serves it.
- An electric machine does nothing until a powered pole covers it, and a
  burner machine outside upkeep's reach (boilers, far drills) runs dry once
  its first fuel is gone unless a feed brings more.
- Price a design in plates and compare that with the plates the factory
  measurably makes. A long belt route can cost more than the line it feeds
  returns for many minutes; short local connections pay back first.
- A design's build time is its total material divided by the slowest measured
  rate at which that material arrives (for a platform, also the payload per
  launch); compare it with the horizon before committing.
- To confirm a feed, measure the consumer's own output: the fed item may also
  be made elsewhere on the surface.

## Geometry

Facts of the base game for designing your own layouts; `can_place` and the dry
run's report confirm each one on the real site.

- A mining drill drops its output onto the tile just past the edge it faces
  (a burner drill beyond its left column, an electric drill beyond its
  middle): whatever stands there receives it, else it lands on the ground.
- An inserter picks up from the tile on one side and drops onto the tile on
  the other. Its direction names the pickup side: direction 0 picks up north
  and drops south, 4 picks up east and drops west.
- One boiler makes steam for two steam engines. Water enters at the ends of
  the boiler's back row and steam leaves from the middle of its front; an
  engine takes steam at either end.
- An offshore pump stands at the shore: it draws from the liquid on one side
  and outputs on the land side. It pumps the liquid it stands in: a boiler
  needs water, so a pump on lava or an oil ocean feeds no boiler.
- A small electric pole powers machines within 2.5 tiles of it and wires to
  poles up to 7.5 tiles away.

## Keep, rebuild or retire

- Every building has a running cost: its fuel, the body's trips to serve it
  (`hand_seconds`: body time serving a line by hand in the last ten minutes),
  and the materials and space it ties up. What it gives back is the flow it
  adds where something uses it.
- Judge older parts again as the factory grows. Building something is not a
  reason to keep it; only what it does for the factory now is. A part that
  costs more than it gives (a far outpost the body keeps walking to, a line
  whose output nothing uses, a burner stage a newer line replaced) is worth
  connecting, rebuilding where it is needed, or removing. Mining it returns
  its items for reuse.

## Bootstrap dependencies

- Many buildings need items made by buildings of the same kind: drills need
  gears, which need plates, which need a fuelled furnace fed by a drill. The
  first of each must come from carried stock, hand-mined resources and hand
  crafting; after that, machines should make the parts.
- An entity in a design that needs a material you do not yet produce (iron
  plates for an iron chest) blocks the whole design until that material flows.
- The cheapest entity that does the job ties up the fewest materials (a
  burner machine needs no power, a smaller container may still hold enough);
  a better one pays once its materials flow.

## Research

- Labs work only on the first technology in the queue, consuming only the
  packs it asks for. A pack it needs that labs lack stalls every lab working
  on it, and an empty queue idles every lab.
- A technology can be queued behind its own queued prerequisites; it starts
  once they finish.
- Research counts toward progress only when machines make the packs and labs
  consume them. A science chain is: plates and gears (red science), then
  inserters and belts (green science), each made by assemblers and carried to
  labs, all powered.
- Assemblers are locked until the Automation research completes, and its
  packs exist before any assembler can make them: those few packs are
  hand-crafted. They do not score, but every machine-made pack depends on
  them.
- Some technologies unlock by a trigger, such as crafting a first item,
  rather than by packs; `progression_status` names the trigger.
- `production_requirements` with a technology lists the packs it still needs;
  with targets it expands any item into its full chain.

## Body time

- Until machines make buildings, every building is hand-crafted, so the
  body's crafting limits how fast the factory grows; an assembler making a
  building item takes that time off the body.
- Crafting from carried intermediates skips each sub-recipe's time: with the
  gears already carried, a recipe that needs them crafts in its own time only
  (a dry run's `hand_craft_s` counts what stock covers).
- Construction robots build ghosts while the body does something else. A
  ghost is only an order, built when a robot brings its item: from a roboport
  network's storage, or from the body's inventory by robots it carries with a
  personal roboport in worn armor (`queue_plan`'s `equip`).

- A plan's active budget is max(570 s, 12 s x its steps) from its start,
  human holds not charged (`queue_plan` says what counts as a step); past it
  the plan fails `PLAN_BUDGET_EXCEEDED` and queued hand-crafts keep running.

## Space platforms

- Asteroids grow in size and gain types along routes away from the inner
  planets. Each one that reaches a platform damages what it hits, and a
  faster platform meets more of them. Turrets shoot only with ammo delivered
  into them; damage research raises their damage (`describe_prototype` gives
  an asteroid's health and resistances and an ammo's damage).
- A platform whose thrusters are destroyed stops travelling. Damage is
  repaired with repair packs (researched), by hand or by construction robots.
- A hub's import request is filled only while the platform is stopped in the
  supplier's orbit. A schedule stop with no wait conditions is left at once.
