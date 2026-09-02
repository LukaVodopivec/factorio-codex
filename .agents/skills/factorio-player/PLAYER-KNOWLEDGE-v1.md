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

Learn through a general state-driven loop: observe authoritative state,
identify the current bottleneck, form a falsifiable hypothesis, predict a
measurable effect, choose a safe action, compare predicted and actual results,
then retain, revise, or discard the lesson with provenance and uncertainty.
Never turn a retained lesson into an opening script, elapsed-time milestone,
fixed build order, named route, or prescriptive progression sequence.
