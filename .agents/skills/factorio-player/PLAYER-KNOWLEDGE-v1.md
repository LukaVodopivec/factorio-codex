# Player knowledge v1

Durable player knowledge may contain only facts learned through honest in-game
play and structured Factorio Codex observations:

- recipes and recipe relationships learned in-game;
- calculations derived from in-game values;
- repeatable operations learned in-game; and
- Codex-authored relative layouts expressed without world coordinates.

Do not store map coordinates, tutorials, external blueprint strings, or online
build sequences. No world position, absolute or relative coordinate pair,
landmark position, entity location, or route belongs in this file. Run-local
coordinates may exist only in the ephemeral `operations.json` ledger with
their source tick and save identity, and expire on reset, contradictory
observation, referenced-entity mutation, or route failure.
Revalidate stale knowledge against current structured game state before using
it. This file defines the versioned contract; it is not a place to persist
save-specific observations.

## Outcome-labelled material-flow knowledge

- `observed-success-condition`: A machine output needs a free physical
  destination that actually accepts the produced item. Count capacity only
  after structured state observes output at that destination.
- `observed-zero-utilization`: `waiting_for_space_in_destination` means the
  producing machine has zero current utilization even if it produced earlier.
- `retained-scaling-check`: Validate and capture existing output before scaling
  upstream input, fuel, or machine count. A destination type or direction that
  failed once is a falsifier for that arrangement, not a universal rule.

Learn through a general state-driven loop: observe authoritative state,
identify the current bottleneck, form a falsifiable hypothesis, predict a
measurable effect, choose a safe action, compare predicted and actual results,
then retain, revise, or discard the lesson with provenance and uncertainty.
Never turn a retained lesson into an opening script, elapsed-time milestone,
fixed build order, named route, or prescriptive progression sequence.
When an exact factor is unobservable, retain only the result of a bounded
falsifiable experiment with its uncertainty, predicted effect, safe bound,
numeric stop, and observed outcome. Never copy layouts, tutorials, or online
sequences.
