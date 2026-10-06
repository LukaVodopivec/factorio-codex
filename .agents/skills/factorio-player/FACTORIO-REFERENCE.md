# Factorio reference

How Factorio's numbers fit together, for planning and diagnosis. Written in
this repository's own words from the game's rules; it holds no layouts,
coordinates, blueprint strings or build orders. Exact values come from the
live game: `describe_prototype` (speeds, energy, mining time, fuel slots),
`production_requirements` (recipes, ingredient chains, craft time) and
`factory_status` / `inspect_entity` (what is actually running). When this file
and a live read disagree, the live read wins.

## Stock, flow and capacity

- **Stock** is what exists now: items in the body, chests, machine slots and
  belts. It answers "can I build this now?".
- **Flow** is items per minute actually moving: what drills mine, furnaces
  smelt and labs consume. It answers "is the factory growing?".
- **Capacity** is the flow machines could reach if fed and emptied. A machine
  with no input, no fuel or a full output has capacity but no flow.
- Progress in a trial is flow that machines sustain on their own. A large
  stock that no machine turns into something else is not progress; a machine
  that only runs while the body feeds it is not yet automated.

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
- **Burning versus reserve.** The item in the fuel slot is the reserve; the
  machine also holds energy from the item it is burning. Removing reserve fuel
  stops the machine soon; it never fixes a full output.
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

## Keep, rebuild or retire

- Every building has a running cost: its fuel, the body's trips to feed or
  empty it (`factory_status` lines show `hand_transfers` and `hand_seconds`,
  the body time spent serving that line by hand in the last ten minutes),
  and the materials and space it ties up. What it gives back is the flow it
  adds where something uses it.
- Mod upkeep refuels burners and feeds labs only within 96 tiles of the
  body (while it is idle, also of where its last plan began). A part further away runs dry unless it is connected or the body
  goes there.
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
- Before committing to a design, check that every entity in it can be made
  from what you carry or can make soon. An entity that needs a material you
  do not yet produce (iron plates for an iron chest, circuits for an
  inserter) blocks the whole design until that material flows.
- Prefer the cheapest entity that does the job now (a burner machine before
  power exists, a smaller container that still holds enough), and upgrade
  once the better one's materials flow.

## Research

- Labs consume science packs only while a research is active and only the
  packs that research asks for. A lab with packs but no active research does
  nothing.
- Research counts toward progress only when machines make the packs and labs
  consume them. A science chain is: plates and gears (red science), then
  inserters and belts (green science), each made by assemblers and carried to
  labs, all powered.
- Assemblers are locked until the Automation research completes, and its
  packs exist before any assembler can make them: those few packs are
  hand-crafted. They do not score, but every machine-made pack depends on
  them, so they are worth their crafting time early.
- Some technologies unlock by a trigger, such as crafting a first item,
  rather than by packs; `progression_status` names the trigger.
- `production_requirements` with a technology lists the packs it still needs;
  with targets it expands any item into its full chain.

## Reading the tools

- `describe_prototype` gives per-machine numbers: `mining_speed`,
  `crafting_speed`, `max_energy_usage` (joules per tick; × 60 for watts),
  `mining_time` and products for resources, fuel categories and slot count.
- `production_requirements` gives recipe executions, ingredient amounts and
  total craft time at speed 1 for a target count. With `per_minute` true it
  does the rate arithmetic above for you: machines per tier, fuel or power,
  drills per raw resource and belt capacity for a target rate.
- `factory_status` gives each production line one `state`: `running`,
  `starved` (input missing; `cause` names it), `output_full`, `no_fuel`,
  `no_power`, `frozen`, `no_heat`, `disabled` or `idle`; its problem rows name
  the machine's own status. Starved and output_full are the flow problems
  above; no_fuel and no_power are energy problems. During a benchmark its
  `trial` shows the time left and the score so far.
