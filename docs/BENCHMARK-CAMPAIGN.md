# Fresh 20-minute benchmark campaign

The root supervisor runs repeated trials under its native Codex Goal until
The owner stops it. The finite `campaign` commands select trials and record scores;
there is no background model loop or additional orchestration service. The owner
may watch the one Codex body and coloured thought feed on the couch PC.

Each trial uses an exact copy of the campaign's read-only baseline save,
peaceful seed 747930220, normal game speed, one body/FIFO/gameplay writer and
one ledger writer. A new campaign starts with the two-session incumbent
(campaign 20261006 screened one to four sessions); `campaign add` supplies each
later one-variable hypothesis. Advisors have mechanically read-only MCP. The solo pilot
owns an empty-package ledger and queues its own plans. Otherwise the strategist
owns the ledger and its build packages queue through the existing pilot bridge.
Every role uses native subscription routing; never fall back to a paid API.

Score automation from native production counters since GO, in order: science
packs labs consumed (research), then plates, gears, circuits and science packs
made by machines, then final-five-minute raw throughput (iron ore, copper ore,
coal, stone). Values within five percent count as equal and the next measure
decides. The mod's run-long hand-craft counter is subtracted from both made
items and consumed packs, so a hand-crafted scored item never counts (hand-made
ingredients a machine turns into a scored item are not traced back). Research
within five packs, made output within twenty items and raw throughput within
five per minute also count as equal, so a handful of items never decides a
comparison. The recorder takes
ordinary snapshots at 5, 10 and 15 minutes, uses a separate control connection
to freeze entity simulation at 1200 wall-clock seconds, and then collects a
frozen final snapshot. Thinking and tool latency count. A native 72000-tick
backup also freezes the trial. Late freezes over one second, a clock that
differs from normal 60 UPS by over 60 ticks, missing counters/checkpoints,
assistance, changed baseline hash, release or profiles make a trial ineligible.
The recorder's run attestation marks a trial assisted by itself when the
baseline or any sample shows game speed other than 1, cheat mode, an editor or
god controller, a mod outside the allowlist, or a modifier research does not
explain (`docs/ARCHITECTURE.md`). Short durations are disposable validation only. Honest model stalls count.

## Finite command interface

```sh
factorio-codex campaign init --campaign <campaign.json> --baseline <save.zip> --id <campaign-name> --release-sha <published-sha>
factorio-codex campaign next --campaign <campaign.json>
factorio-codex campaign status --campaign <campaign.json>
factorio-codex campaign add --campaign <campaign.json> --profile <configuration.json>
factorio-codex campaign record <run-id> --campaign <campaign.json>
factorio-codex campaign pause --campaign <campaign.json>
factorio-codex campaign resume --campaign <campaign.json>
```

Initialization copies the baseline beside campaign.json with mode 0400 and
records its SHA256. `next` is stable until the pending trial is recorded.
Configuration JSON contains `id`, `release_sha`, `change`, `family` (topology,
model, instructions, mod or interaction), and `profiles`. Each profile names
`id` (pilot/strategist/mining/logistics), `role` (pilot/strategist/advisor), `model`,
`reasoning`, `fast`, and `ledger_writer`. There must be one pilot and one
ledger writer. A changed hypothesis always gets a new configuration id.

The supervisor copies the baseline into a new run directory, installs that
configuration's published mod, archives the previous ledger/package outcomes
into their own run, and starts fresh role sessions with detailed reasoning
summaries. It creates each own notebook folder and rollouts.json mapping role
ids to native rollout files. No role reads another run's notebook. Normal
server create/start/stop and the native couch spectator remain the only paths.

Before GO follow LIVE-VALIDATION.md's delivery, retirement and stop rehearsal
with a disposable session. Record exact session/turn identities and receipt
times, consume each fresh current/next settings report, and match the frozen
profile. Verify native subscription routing. End settings preparation turns
before rereading; updates are not confirmation. The sole writer initializes
the fresh ledger with no packages. Start the finite recorder with:

```sh
factorio-codex runs record --ledger <operations.json> --variant <configuration-id> --change <hypothesis> --kind benchmark --incumbent-summary <reference>
```

Its GO receipt establishes the clock. Deliver GO to these exact role sessions.
At cutoff, pause each native role goal and interrupt/retire its exact active
turn; confirm no further gameplay or ledger writes. Reconcile pending physical
work while the simulation is frozen, record the score, save/stop the owned
server and recorder, close owned role sessions, and start the next fresh trial.
Never continue a prior factory as a scored fresh trial. Interrupted trial
selection/evidence persists: finish reconciliation and exclude it before
restarting; do not silently overwrite a manifest or baseline. After retiring
writers, settling committed work and stopping a dead recorder/server, use
`runs interrupt <run-id> --reason <reconciliation>` to close a leftover
recording manifest as interrupted. This preserves samples and never makes the
run eligible. `campaign record` excludes malformed/partial sample evidence
and retries the same configuration with a new run id.

## Search and confirmation

A promising screen opens three fresh paired trials, ordered challenger/
incumbent, incumbent/challenger, challenger/incumbent. Promotion requires at
least two pair wins and over five percent median research gain, or over five
percent median machine-made gain while median research is within five percent. Invalid
trials repeat the same pending configuration without advancing confirmation.
Recheck the incumbent after six screens. When the queue is exhausted the
supervisor adds a concrete next hypothesis rather than a random combination.

After topology screening vary one role's model, effort or Fast mode at a time.
Then test instruction or deterministic mod changes motivated by recorded
failures. Freeze source/prompts/settings throughout each trial; publish and
verify changes between trials. After ten unsuccessful screens switch variable
family. Keep the best confirmed configuration as incumbent while searching
indefinitely. Periodically summarize scores, exclusions, bottlenecks, settings
and next hypothesis in the campaign evidence. The in-game panel displays the
profile, remaining time, research, machine-made and raw totals and the incumbent reference; the
panel shows the ledger writer's reasoning, and every role's lines are saved to `thoughts.jsonl`.

An explicit owner stop pauses the campaign and follows LIVE-VALIDATION.md's
recorded stop procedure: stop FIFO, pause/interrupt roles, settle in-flight
writes, re-observe, finish recording and save/stop the owned server. Human
takeover or supervisor repair excludes that trial. No scored run is nudged,
replaced for low growth or rescued. Human WR replay/video analysis is kept as
separate supervisor-only reference evidence, with exact, visually estimated
and unknown milestones distinguished; it never supplies layouts or sequences
to gameplay roles.
