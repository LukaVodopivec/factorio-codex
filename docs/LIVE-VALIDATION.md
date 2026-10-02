# Live validation

This runbook validates release **0.19.5**. Prior live evidence remains historical
until the fresh 0.19.5 run is recorded. The Linux workstation has no dedicated
GPU and is permanently headless: run only the dedicated server, Node bridge,
and agent tooling there. Never start a Factorio GUI/client or any other visual
GUI workload on that workstation during rollout, validation, or a benchmark.
Both visual Factorio processes run exclusively on the couch PC. The
`scripts/launch-native-client.ps1` entrypoint is couch-only; the repository does
not provide a Linux visual client launcher.

1. On the couch PC, install the full standalone Factorio 2.0.x Space Age build under
   `%LOCALAPPDATA%\factorio-codex\standalone-space-age`, or pass its executable as
   `-FactorioBinary`. The Steam build is intentionally rejected for the Codex
   client because it replaces the isolated LAN identity.
2. Run `nvm use 22 && npm ci && npm run build && node companion/dist/cli.js setup`.
3. Host a dedicated Space Age fresh freeplay save from one run directory with
   permanent peaceful mode and enemy bases disabled:
   `node companion/dist/cli.js server create <run-dir>`, then
   `node companion/dist/cli.js server start <run-dir> [--bind <lan-address>]`.
   The run directory owns its save, logs, PID, and a run-local mod directory
   with base, elevated-rails, quality, space-age, and the companion enabled, so
   stale global mods never load. `server start` refuses a protocol or mod
   version mismatch before `GO`; `server stop <run-dir>` saves over RCON and
   shuts the server down at the run boundary instead of leaving it idle. Both
   server and couch client run the identical Space Age mod set.
   Console-backed RCON disables achievements for the save. Play is
   Nauvis-first: the MCP has no rocket, space-platform, or planet-travel tools
   yet.
4. From the couch PC, run
   `scripts/launch-native-client.ps1 -Address <server:port>` to connect the
   isolated low-resource native client as the real player named `Codex`, before
   starting the normal couch Factorio client as the viewer. Its write-data and
   mod profile lives only in `%LOCALAPPDATA%\factorio-codex\native-client`. Run
   `node companion/dist/cli.js doctor`, start Codex at the repository root,
   then call `connect_status` and `observe_local`. Confirm the mod refuses an
   absent or wrong player instead of creating a standalone character.
5. Physically mine resources; place a burner mining drill and stone furnace;
   insert legitimately acquired fuel; wait; inspect; extract. Confirm inventory
   changes, elapsed ticks, full footprints, honest reach and path failures.
   Verify `mine` count repeats cycles only on its initial exact resource and
   that `observe_local` reports resources as connected patches with an exact
   `nearest_target`, not duplicate entity rows. Observe an exact `ground_items`
   stack, call `pickup_items` with its unchanged position/item/count, and verify
   ordinary walking/ticks, target depletion, and the matching inventory delta.
6. Run a two-or-more-step `run_plan`. Confirm ordered fail-fast outcomes, no
   later enqueue after failure, and a final observation on completed, failed,
   and cancelled paths. Confirm Codex walks at ordinary Factorio speed and no
   global game-speed setting changes.
7. Interrupt a long action in the TUI, then call `stop`.
8. Exercise `find_placement` at a shoreline; confirm `map_summary` reads only
   force-charted chunks; verify deterministic production arithmetic and
   ambiguity refusal. Find a cardinal inserter placement with an exact
   `output_target`, physically place it with that target, and distinguish its
   live output point's valid 1×1 recipient geometry from runtime binding. A nil
   `drop_target` before first output must remain explicitly pending, not fail or
   claim binding; a non-nil different target must fail. For a mining drill,
   include legitimate starter fuel in the same build-plan step and confirm the
   plan waits until actual output flow exposes the exact runtime recipient.
   Inspect the placed inserter's `pickup_target` to
   falsify an incorrect source binding. Confirm an output-capable candidate always
   reports `output_position` and reports its recipient or explicit `null`; a
   selection-box-only furnace overlap must not pass exact target filtering.
   Confirm mining-drill candidates report
   only compatible resources whose centers are covered by their mining area; treat a
   deterministic rejection count for charted candidates with zero compatible
   resources and treat omitted coverage as uncharted. Inspect the live inserter
   and confirm its pickup/drop positions and valid target identities; confirm
   belt contents, a mining drill's actual output position, recipient-or-null and
   `drop_target_bound`, its current resource target, and exact furnace
   fuel/input/output buffers only where the corresponding inventory exists.
   Force a bounded no-path/stall fixture and confirm only its immediate charted
   collision segment, stable capped inferred visible collision candidates and
   collision tiles—not an authoritative blocker claim—or the explicit absence
   of an identified blocker. Confirm a terminal
   `plan_status` still carries only the assigned `queued`, first `running`, first
   applicable `waiting`, and truthful final transition after a fast successor.
   Then physically connect steam power to an
   electric drill and deliver mined ore through belt, pipe, and power routes.
9. If bootstrap items are absent, use another fresh built-in freeplay save.
   Gameplay roles never use console commands, editor mode, spawned items, or
   teleporting. A debug supervisor may use those surfaces only for recorded
   diagnosis or the smallest recovery intervention, after which the pilot must
   re-observe authoritative MCP state.

For the 0.19.5 reliability pass, also record these observable checks without
turning them into a fixed opening or map-specific sequence:

- A compact observation stays bounded, names every omission count, and appears
  once as structured content with only a short text summary. Full detail remains
  available only when deliberately requested.
- A freshly observed natural target either mines by exact identity or returns a
  named diagnostic distinguishing exact-coordinate resolution, physical reach,
  and engine selection. Re-observe after any stale-target result.
- A genuine no-path case reports only charted local collision evidence, any
  owned collision cage, and the best bounded reachable frontier/partial route;
  it neither walks that partial route automatically nor reveals uncharted state.
- A deliberately split electrical route reports successful pole placement
  separately from endpoint coverage and network continuity. Add an honest
  bridge and confirm the later result becomes connected; do not equate either
  result with a powered, working consumer without inspecting that consumer.
- A producer and its recipient can be preflighted when the recipient is an
  earlier placement in the same build plan. Wrong endpoint geometry fails
  before mutation, while runtime binding remains exact and pending until first
  output when appropriate.
- An out-of-range `wait_for_item` fails immediately with the physical-distance
  correction instead of consuming its timeout. An insertion that accepts only
  part of a request terminates as `partial`, reports requested/inserted/remainder
  counts, preserves the useful accepted amount, and does not execute dependent
  steps.
- Queue and plan responses carry a self-describing `terminal` state and exact
  `next_action`; a terminal continuation handle is never waited a second time.
- A plan with `observation_detail=none` returns compact outcomes, execution
  metadata, and inventory deltas without an embedded observation. Explicit
  compact/full requests retain bounded detail and omission counts.
- A bounded `plan_status` wait returns on a meaningful step outcome, waiting
  state, or terminal result. A monitoring timeout does not cancel the plan and
  returns a self-describing continuation.

## Full graph and downstream acceptance validation

Offline Lua fixtures and MCP tests verify graph computation versus capped
presentation and validation failure cases; they are stub evidence, not live
Factorio evidence. Live confirmation requires an installed supported Factorio
2.0.x game. No deployment or server/client replacement is implied by offline
checks.

- Observe an already charted connected segment exceeding 12 nodes and 24 edges.
  Confirm full component counts and accurate presentation omissions. Select
  exact positions beyond returned rows with `validate_factory_component`; an
  unrelated component's presentation omissions must not reject the segment.
- Observe a physically supplied drill–furnace–chest segment with ordinary fuel
  supply and power. Confirm `downstream_kind=buffer`, then validate an unattended
  interval with at least three processor cycles, three observed drill cycles
  (progress wrap plus depletion of the same charted resource) and three distinct
  arrival samples for each relevant output item. Sampling aliasing, unsupported
  source counters and shared mining-target attribution remain unproven. Contrast with a working consumer-ended segment reporting
  `downstream_kind=consumer`. A buffer is storage, never a consuming sink or a
  production source inferred from existing stock; agents decide its usefulness.
- Also check a processor-free source-to-transport-to-buffer or consumer segment.
  Require three observed mining-progress wraps with same-target depletion per
  source and three distinct acceptance samples per relevant output at every
  endpoint, unchanged topology, complete transfer history and zero component
  transfers. Require processor cycles only for processors actually present;
  source-only proof may have `products_finished_delta=0`. For a burner mining
  its own fuel, record the exact directed physical return bindings. Compatible
  mined output and finite starter stock alone cannot prove replenishment.
  Topology readiness and local operation alone are not `autonomous_end_to_end`.
  A working consumer must accept every relevant output through its native input
  inventory at each counted sample. Reject incompatible outputs, full inputs,
  and unsupported consumer or fluid acceptance; unrelated stocked inputs and
  working status alone cannot prove endpoint acceptance.
  The historical coal-buffer increase and offline fixtures do not prove live
  autonomy; live evidence needs the exact deployed source/archive identity and
  a fresh structured multi-tick interval. A queued terminal belt rotation is
  not a completed repair; retain its orientation diagnostic until re-observed.
- Make the buffer full or nonaccepting. Confirm `blocked_output` and revoked
  current autonomy. Buffer capacity alone and production without accepted
  arrivals must never establish autonomous operation. Unsupported buffer
  acceptance remains unproven; no exact remote inventory/fluid counts appear.
- In an authorized supported Factorio 2.0.x run, observe an exact connected
  fuel-return inserter waiting at the burner's ordinary replenishment target
  while useful production continues, both with held fuel and with an empty
  held stack. For the empty case, capture the supported burning pair and the
  single matching stocked fuel/quality pair; never read empty-stack identity.
  Capture `identity_source`, pickup/drop
  bindings, compatible upstream production, working burner with remaining
  energy, matching stocked fuel and fuel-inventory space. Confirm the waiting
  status stays visible with `fuel_return_saturation` and the corresponding
  diagnostic's `nonblocking_reason`, while that branch alone does not set
  component `blocked_output` or either other output blocker. Do not infer the
  normal replenishment target from a hard-coded count or relabel the inserter
  as working. Unsupported or ambiguous compartment/fuel evidence stays blocked.
- Observe exact `waiting_for_source_items` snapshots at preflight and during
  sampling on both a fuel-return and a material-transport inserter. Confirm the
  normalized shortage and diagnostic remain visible, with `transport_wait`
  evidence and `validation_nonblocking_reason` explaining provisional sampling.
  Record later working resumption of each waiting inserter, all required source
  and processor cycles, matching acceptance at every endpoint and zero transfers.
  Persistent waiting must fail even when independent downstream stock grows;
  generic `insufficient_input` must still fail preflight. A current waiting
  snapshot must revoke an existing public autonomy claim.
- Observe fuel consumption, resumed ordinary replenishment, and renewed waiting
  with unchanged topology. Record continued source/processor production,
  downstream acceptance and zero character transfers across the bounded
  validation interval. Then independently exercise genuine productive-output
  and full/nonaccepting buffer blockage, incompatible/unresolved fuel, and the
  end-belt orientation diagnostic; each must still reject autonomy. Do not
  repair a belt layout merely to remove that diagnostic in this check.
- Check positive burning energy and matching compatible stocked fuel at every
  sample, including after the return inserter resumes working. Independently
  remove stock, interrupt burning energy, make fuel evidence unsupported or
  contradictory, and keep downstream output growing through another branch.
  Each broken return must still reject validation and revoke current proof;
  aggregate output growth is not continuous fuel evidence.
- Record the exact deployed source revision and mod archive digest with live
  structured observations. The Lua saturation/replenishment fixture is offline
  simulated evidence, not confirmation of the reported release 0.19.5 live
  observation or any later deployed candidate. This source change has no live confirmation or deployment;
  perform that check only in a separately authorized run, without restarting or
  altering an unrelated active run.
- During separate validation intervals, interrupt fuel/power, change a physical
  relationship, stop production, or perform a character transfer. Each must
  produce structured rejection. Check complete transfer attribution even when
  the public target-action rows are omitted. Bounded validation samples the
  interval; it cannot guarantee every intervening tick or future buffer demand.

## Persistent two-brain, one-writer contract

The dedicated server and agent session run on the headless workstation, while
the exact `Codex` client and characterless spectator/follower run only on the
couch PC. Do not launch a local GUI as a recovery shortcut.

The next fresh supervised-debug topology has exactly two persistent reasoning
sessions and one physical writer. Start the sole gameplay pilot as
`gpt-6-luna` with `low` reasoning and fast mode enabled. Start the persistent
strategist as `gpt-6.1-sol` with `medium` reasoning at normal speed and expose only the disabled-
by-default `factorio-readonly` MCP server to it; disable the full `factorio`
server in that Sol session. Sol owns NOW/NEXT/LATER and is the sole atomic writer
of one compact `operations.json`, including its initial revision. The ledger is
Sol's only channel to the pilot. Sol designs every coupled layout as a build
package checked with `find_placement` and `can_place` (the only coordinates in
the ledger); Luna revalidates and queues packages unchanged and owns immediate
safety, travel, gathering, physical plans, actions, and latest exact local
evidence. Sol reads never enter
the physical FIFO, and Luna continues without waiting when Sol or its ledger is
stale or unavailable. Record both profiles, their MCP surfaces, release SHA,
archive hash, and save hash before `GO`. Never apply this cutover to the current
run.

Launch the two connected sessions from the repository with `session-launcher`.
The pilot needs no MCP override: the project `.codex/config.toml` defaults are
already its surface. Connected (`--remote`) clients validate `-c` overrides
before the project layer loads, so a role override must name a complete server
table; a partial `mcp_servers.<name>.enabled` override fails with
`invalid transport`.

```sh
session-launcher --name factorio-pilot --model gpt-6-luna --reasoning-effort low --fast on
session-launcher --name factorio-strategist --model gpt-6.1-sol --reasoning-effort medium --fast off \
  -c 'mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=[],enabled=false}' \
  -c 'mcp_servers.factorio-readonly={command="./scripts/start-factorio-mcp",args=["--surface","read-only"],enabled_tools=["connect_status","map_summary","progression_status","production_requirements","describe_prototype","observe_local","inspect_entity","plan_status","can_place","find_placement"],enabled=true,required=false,startup_timeout_sec=180,tool_timeout_sec=600}'
```

The launch flags express requested settings. `--fast on` requests
`service_tier="priority"` plus `features.fast_mode=true`; `--fast off` requests
normal service. Neither a launch flag nor a successful update is role-profile
confirmation. Follow the native readback procedure below before `GO`.
Start each with its checked-in role goal; the pilot takes no physical action
before `GO`. Confirm Sol lists exactly the ten
configured read-only tools (including the side-effect-free placement checks) and cannot list any movement, transfer, crafting,
placement, research mutation, plan enqueue/run/cancel, or stop tool before
`GO`, and that the pilot has the full surface and no read-only server.

Before `GO`, verify the requested fresh save and release hashes, permanent
peaceful mode/enemy bases disabled, exact native player, viewer, and one
body/lane/writer. Archive the previous run's `operations.json` into that previous
run's directory and verify the current ledger destination is absent. Give Sol
the new ledger's absolute path and the exact `run` object
(`id`, `release_sha`, `baseline_save_sha256`, `save_identity`, `created_at`,
`roles` per the ledger schema), and have Sol create it by piping an
`{"init": true, "run": <that object>, "source_tick": null, "update": ...}`
envelope to `node_modules/.bin/tsx companion/src/cli.ts ledger-apply --ledger
<absolute operations.json path>` from its worktree. Supply a fresh observed
`source_tick` when available; `null` means no observation yet. Fill `update`
with the validated current mutable fields (`phase`, `bottleneck`,
`latest_measured_capacity`, `task_list` with NOW/NEXT/LATER, `assumptions`,
`pilot_plan_ids`, and `build_packages`, usually `[]` at init; every later update
restates it). Verify the receipt returns `status: "applied"`, revision 1,
and the submitted source tick; verify the persisted schema-2 ledger contains
the exact run metadata, revision, source tick, mutable content, and mode `0600`.
The command validates this readback before reporting success. Initialization
refuses every existing destination, including malformed ledgers, without
replacement. Subsequent reports use the unchanged
`{run_id, save_identity, source_tick, update}` envelope and require a newer tick;
an ordinary update cannot initialize an absent ledger. Never hand-seed revision
0: Sol is the sole atomic host writer, including initialization, and Luna
continues fail-open if Sol or the ledger is missing, malformed, stale, or
unavailable. On any resumed save or after a mod upgrade,
reconcile retained work: if `observe_local` reports an active task or queue
depth, call `stop` and re-observe until idle, and treat pre-`GO` plan IDs as
invalid `after_plan_id` values. Rehearse the stop sequence below on the live
role sessions without stopping the server; a role turn must end within about
five seconds of pause plus interrupt. Then resume both role goals through the
native procedure below before starting the recorder; an active goal plus an
idle thread does not prove that queued `GO` will start a turn. Continue past
20 minutes toward the assigned milestone
(currently sustained autonomous Nauvis production: a validated
`autonomous_end_to_end` segment that still holds at the next two recorder
checkpoints, plus useful research consuming produced science); Candidate B and
R1-R7 freeze rules are historical unless the owner starts a benchmark.

### Native role-profile evidence before GO

Use the existing connected session transport, exact role thread/turn identities,
and existing run evidence. Add no launcher wrapper, enforcement hook, evidence
store, ledger field, or gameplay control channel. Apply this procedure only at
the fresh-run preparation cutover; never reconfigure an active gameplay role.

The [official configuration reference](https://developers.openai.com/codex/config-reference)
defines `features.fast_mode` as enabling model-catalog service-tier selection
controls. It describes `service_tier` as a preference for new turns, with `fast`
mapping to `priority`. Separate four kinds of evidence:

- **Requested:** launch flags or the exact `execution_settings` update values.
- **Current turn:** native `current_turn.model`, `reasoning_effort`, and
  `service_tier`; an update does not retroactively change this turn.
- **Next turn:** native `next_turn` model, effort and tier; a successful update
  with `effective:"next_turn"` establishes a request for subsequent turns.
- **Availability/inheritance:** `fast_mode_enabled` and
  `fast_inherited_from_root` when available, preserved verbatim. Verify their
  semantics in the installed runtime, rather than equating similarly named
  fields. The disposable 0.159.2 probes below establish that its enabled flag
  follows the selection feature, independently of the selected Fast tier.

Each exact role calls native `execution_settings({})` in preparation and sends
a compact structured projection copied verbatim from the native result to the
supervisor: both model/effort/tier triples and the availability/inheritance
fields, plus exact thread/turn identity and separate requested values. Keep the
message below the existing 1,000-byte transport limit; exclude unrelated
context, usage and model-catalog fields. Keep requested values separate;
do not reconstruct readback from a launch command or substitute the supervisor's
own settings. Record session and turn identity, native runtime version,
observation receipt time, requested values, reported values and interpretation
in existing run evidence. This preparation report uses the existing session
transport to the supervisor; Sol's only channel to the pilot remains the ledger.
All required profile fields fit this compact projection. If fuller native output
is needed, the supervisor reads it through the existing session transport and
records it in existing run evidence; do not add a store or channel.

If preparation changes a role profile, retain the update receipt, end that
turn, and obtain a fresh native read in the subsequent turn. Require both
`current_turn` and `next_turn` to match Luna / low / Fast (`priority` in the
validated runtime) or Sol / medium / normal (`default` in these probes,
`standard` only when the installed runtime establishes that mapping).
`changed:false` on a read means no update was requested, not failed preparation.
Missing fields, unresolved null tiers, wrong identity, malformed or stale
reports, delayed delivery and unexplained contradictions hold `GO`. Resolve
with the exact role and a fresh read; never silently treat them as confirmation.
Any later settings update invalidates the earlier report.

The supervisor explicitly consumes and records its assessment of **both** fresh
reports before authorizing `GO`. Sending or queuing a report does not prove
consumption. A report that arrives after this assessment requires reassessment;
if it arrives after `GO`, record the missed preparation evidence and qualify the
run rather than retroactively claiming compliant preparation. A true selection
feature flag with current/next normal tiers is consistent in the validated
runtime: preserve it as capability evidence and judge selected normal speed by
the tiers. Any other unexplained conflict must be resolved before `GO`; the flag
alone does not establish a native bug.

These tiers describe native selected thread/turn settings. They do not by
themselves prove provider processing. Record provider-confirmed processing tier
separately if the transport exposes it; otherwise state it is unavailable and
claim only the selected profile. Never infer provider confirmation from latency,
a feature flag, a model catalog, or a role's prose summary.

**Verification evidence and limits (2026-10-02).** Disposable persistent
native 0.159.2 app-server sessions used the existing stdio JSON-RPC mechanism,
with configured MCP servers disabled, a read-only sandbox, and no gameplay
goals. Experimental raw tool-output events supplied actual `execution_settings`
results, not inferred launch values. Receipt times below are UTC:

| Probe / receipt | Native current turn | Native next turn | Enabled / inherited | Supervisor interpretation |
| --- | --- | --- | --- | --- |
| Luna, 01:14:15 | Luna / low / priority | Luna / low / priority | true / false | Pilot selected Fast profile confirmed; no GO while Sol report absent. |
| Sol delayed until 01:14:42 | Sol / medium / default | Sol / medium / default | true / false | Both reports now consumed; normal tier and true flag retained separately, not classified as a bug. No gameplay GO was sent. |
| Sol requests Luna/low/fast:true, 01:14:49; same-turn read | Sol / medium / default | Luna / low / priority | true / false | `changed:true`, `effective:next_turn`; preparation incomplete despite update success. |
| Subsequent turn, 01:14:54 | Luna / low / priority | Luna / low / priority | true / false | Fresh native read confirms application after the turn boundary. |
| Requests Sol/medium/fast:false, 01:14:56; same-turn read | Luna / low / priority | Sol / medium / default | true / false | Disabling Fast selects default for next turn while selection capability remains enabled. |
| Subsequent turn, 01:15:00 | Sol / medium / default | Sol / medium / default | true / false | Fresh normal profile consumed; true flag is capability evidence. |
| Separate session with features.fast_mode=false, 01:15:05 | Sol / medium / null | Sol / medium / null | false / false | Controlled feature-off probe changes the enabled flag; null tier remains qualified, not normal-profile confirmation. |

The supervisor withheld profile approval while Sol's report was outstanding
for 27 seconds, then consumed both structured reports. The delay was controlled
by requesting Sol's read after Luna's; it does not test transport congestion.
The supervisor withheld confirmation across each mismatched current/next update until the subsequent-turn read. This
is a disposable preparation exercise, not a live GO test. The feature-on/off
comparison verifies the installed flag's capability meaning for these probes;
it does not prove identical semantics in other versions or inheritance behavior
for child sessions. Recheck after runtime changes. Provider processing tiers
were not exposed in these settings results, so only native selected tiers are
confirmed. Cleanup read all three test threads idle, archived them through native
session controls, and observed the test app-server exit successfully. Initial
transport-reader sampling was corrected before these complete probes; two
preliminary sessions were also archived. No active gameplay role, shared native
setting or credential was changed; no live run, mod deployment, server restart,
or gameplay-performance claim follows from this validation.

Repository-native offline verification used Node 22.23.2: the two-brain contract
passed all 10 tests, the focused verifier passed all 15 Python tests, and quick
and full passed all four and ten declared checks in a standalone checkout with
byte-identical source at the time of those runs and the existing installed
dependency tree. Subsequent changes were documentation only (compact-report
wording and this evidence record); the two-brain and diff checks were rerun
afterward.
Initial preserved-worktree quick/full attempts reported an owning-checkout
dependency-descriptor mismatch or missing descriptors; they did not establish
which condition caused it. The standalone check supplied a matching real owning
checkout without altering the verifier.
an earlier issue remains separately owned; this correction changes no verifier code or
suppresses any check. Fresh independent read-only review found a preparation
message-size conflict; the compact projection above resolves it (a representative
message with native Sol values and UUID identities is 417 bytes), and the
reviewer confirmed the transport fix. A subsequent evidence-coverage finding
was resolved by qualifying which source the broad checks covered, as above.
Offline results do not prove
live role preparation, provider processing tiers, or improved gameplay.

After integrating the advanced 0.19.2 target, the instruction patch remained
unchanged. The preserved worktree's own quick/full verification then passed all
four/ten declared checks under Node 22.23.2; an exact committed standalone clone
also passed both profiles. The integrated two-brain contract passed all 10 tests.
A fresh independent read-only review found no integration conflict: upstream
idle reporting, plan sizing and native GO resumption remained intact. These
checks covered the integrated source before this evidence-only update; the
final focused contract and diff checks were rerun afterward. The earlier
prerequisite failure remains historical, not a current readiness failure.

### Native resumption after the stop rehearsal

Use the existing connected app-server session controls for each exact role,
not a new session or gameplay path. Discover the installed protocol with
`codex-real app-server generate-json-schema --experimental --out <scratch-dir>`
and use the role daemon's existing connection (or `codex-real app-server proxy
--sock <role-daemon-socket>`). Initialize the JSON-RPC connection with
`capabilities.experimentalApi=true`. Retain the exact `threadId` from the role
session and every returned `turn.id`; names, the latest roster entry, and a
supervisor's own thread are not substitutes. The installed 0.159.2 protocol
provides `thread/goal/get`, `thread/goal/set`, `thread/read`,
`thread/queue/add`, `thread/queue/list`, `thread/queue/start`, `turn/interrupt`,
and `turn/started` / `turn/completed` notifications. Recheck the installed
schemas when the runtime changes; a schema establishes capability, not success.

1. Preserve the rehearsal's physical stop, goal pause, turn interruption,
   settled task-owned commands, stopped Sol ledger writes, and fresh physical
   quiescence. Read back each exact paused goal and interrupted/completed turn.
   Pause may itself settle a turn: if an interrupt reports no active turn,
   inspect that exact turn before deciding whether anything remains to stop.
   An interrupt response alone does not prove settlement; retain the matching
   `turn/completed` notification and current thread readback.
2. Resume each existing goal with `thread/goal/set` using
   `{threadId, status: "active"}`. Resume can immediately start a continuation
   turn. Interrupt that exact resumed turn as part of the rehearsal and await
   its settlement; it must perform no pilot physical action. Read back the
   active goal and idle thread. Do not start a separate reconciliation turn to
   test readiness. First prove this release procedure on disposable
   non-gameplay sessions through the same native connection mechanism, with
   no Factorio tools; preserve the exact-role capability checks above.
3. Start the recorder and obtain its baseline before releasing either role.
   Submit one `GO` per role with `thread/queue/add` using
   `{threadId, clientUserMessageId, input: [{type: "text", text: <GO>}]}`.
   The pilot's GO text names Sol's exact thread ID, as does any replacement
   pilot's assignment, so the pilot never reads threads to address reports.
   Choose and retain one unique client message ID for each role's GO. The
   response's `queuedSubmission.id` proves acceptance only. Read
   `thread/queue/list` for that thread to identify the pending submission;
   queued delivery is not consumption and does not prove a turn will start.
4. At GO, release each pending submission with `thread/queue/start` using
   `{threadId, queuedSubmissionId: <returned id>}`. This consumes the existing
   GO; do not send another GO or an empty `turn/start` reconciliation request.
   Record the common GO timestamp at the first release dispatch, plus each
   role's actual start receipt and recorder tick. Record any assigned absolute
   stop deadline once from that GO boundary. Retries, delayed role starts,
   resumption, and recovery never reset or extend it. If the deadline arrives
   during recovery, execute the explicit-stop sequence, not another release.
5. Match the returned turn ID and `turn/started` notification to that thread.
   Confirm the pending submission disappears from `thread/queue/list` and the
   turn's `userMessage` item contains the same `clientId` and GO text; retain
   the role's response acknowledging consumption. These are distinct receipts
   for acceptance, pending delivery, consumption, and turn start. Before any
   retry after a timeout or uncertain effect, read the goal, thread, queue,
   and exact turn history (`thread/read` with `includeTurns:true`, or the
   installed paginated turn/item reads). If GO was consumed or a turn started,
   do not enqueue or start it again. If an active/pending turn is reported,
   resolve its identity and settlement before release; never overlap role
   turns or treat an idle roster sample as proof that no start is pending.
6. Observe a later native goal continuation turn after the GO turn ends while
   the milestone remains open. The supervisor does not assign every batch.
   Keep exactly the two persistent roles, one body and FIFO lane: Luna alone
   writes gameplay, Sol keeps its read-only surface and alone writes the
   ledger. The supervisor's native session control is not a gameplay writer.

**Verification evidence and limits (2026-10-02).** The installed Codex CLI
0.159.2 generated the experimental native schemas. Disposable persistent
app-server sessions, using native stdio and connected Unix WebSocket JSON-RPC
transports with every configured MCP server disabled and a read-only sandbox, exercised
`gpt-6-luna` / low and `gpt-6.1-sol` / medium separately. Both rehearsed pause,
interruption, resume, and interruption of the automatically resumed turn.
Their goals read active and threads idle, yet each GO remained in
`thread/queue/list`. Exact `thread/queue/start` removed that submission,
returned a turn ID, emitted the matching `turn/started`, and recorded a
`userMessage` with the submitted client ID. Both answered `GO_CONSUMED`,
completed that turn, and then automatically started and completed a distinct
native goal continuation answering `CONTINUATION`, without another start
request. In the stdio samples, rehearsal/resume interrupted-turn durations
were 6/8 ms for Luna and
4/13 ms for Sol; these disposable timings do not establish live-role stop
latency. Cleanup read both goals paused and threads idle, archived the test
sessions, and observed the test app-server processes exit successfully.

This proves native session resumption and continuation over those transports,
not the running human daemon, live gameplay, physical stop latency, recorder
behavior, or ledger quiescence. Rehearse through the actual connected role route before a live GO.
The release 0.19.1 cycle-2 queued-GO incident is the reported motivation, not
new live validation evidence. Claim live success only after an authorized
supervised run records both roles consuming GO and subsequent pilot physical
work through the ordinary lane. No mod release or deployment is required for
this documentation correction.

For the 0.19.0 role split, measure at `GO+20m` against the 0.18.0 baseline in
`docs/AGENT-PLAY-PERFORMANCE.md`: first `queue_plan` within 3 minutes of `GO`
(was 13.6); pilot model time under 60% of wall time (was 96%); body busy (active
task or queue depth) at least half the time after the first package; at most 3
pilot `find_placement` calls and no identical empty retry; at least 80% of
packages passing pilot revalidation; at least 6 machines and 4 physical edges
(was 2 and 1); no supervisor nudge; and no Sol-to-pilot message.

The parent is the debug supervisor and may diagnose or recover through its
separate surfaces. That authority does not pass to the pilot. Record each
intervention and obtain a fresh structured observation before ordinary play.
The supervisor yields its own turn between recorder checkpoints and records the
structural-growth deltas defined in `AGENTS.md` at each one.

For an explicit the owner stop, record each step: call factorio `stop` (cancels the
active task and every queued plan within seconds); in each role TUI run
`/goal pause` and read back the paused state; interrupt any active role turn
with the native TUI stop control or app-server `turn/interrupt` for that role's
exact `threadId` and `turnId`, and read back the interrupted turn; check
separately that no task-owned command or job is still running; confirm Sol
makes no further ledger write; then run recorder FINISH and
`server stop <run-dir>`. The debug supervisor of this contract may use these
native controls on its own role sessions as recorded interventions. A steered
`CANCEL` reaches a busy role at its next step but stops nothing by itself.

### Supervisor stall and replacement validation

Follow the authoritative stall contract in `AGENTS.md`; this is a manual
supervised procedure, not an executable supervisor. Before `GO`, record a
confirmed message delivery from the current supervisor to the exact pilot
session. Verify interrupt/retirement and observable inability to resume using
a disposable non-gameplay session with the same session mechanism; confirm
that the route is available for the exact pilot. Do not retire the prepared
pilot as a capability test. Missing delivery or retirement capability must be
resolved before `GO`.

While milestone goals remain open, use fresh valid `observe_local.character`:
`active_task` absent, numeric `queue_depth == 0`, and numeric
`crafting.queue_size == 0` together prove idle. A missing character or required
queue/crafting field, malformed response, stale sample, or failed call is
uncertain, not idle. An absent `active_task` in an otherwise valid complete
character observation is the normal no-task representation. Parked waiting
plans and predecessor-blocked queued plans count as pending work. Inspect a
known plan only with its exact `plan_id`; `plan_status {}` is invalid.

Record receipt timestamps and character position, carried inventory,
task/queue state, and crafting state/progress in existing run evidence. Retain
the last evidenced physical-change/idle-transition timestamp that establishes
the current idle interval across unchanged samples. Advancing ticks and
unrelated factory output do not reset it. If the transition is unknown, such
as between an active sample and an idle sample, report a conservative observed
lower bound starting at the first valid idle sample, not an invented exact
start or the next unchanged sample. Renewed activity resets timing and the
single-nudge state; a run change or uncertain observation invalidates timing.
Re-establish a fresh lower bound after uncertainty rather than counting the gap.

At about two minutes, revalidate idle evidence, deliver one nudge per interval,
and record its receipt. Failed or uncertain delivery is a capability problem;
read back delivery state before retrying and do not claim a nudge succeeded.
At about five minutes, freshly revalidate continued idleness, interrupt and
retire the old pilot, and confirm it cannot resume gameplay writes. Settle any
in-flight physical call: wait for its definitive outcome or resolve uncertainty
through structured state before proceeding. Interruption does not roll back
committed plans. If emergency cancellation is necessary, record `stop` and its
effects. Then freshly prove absent active work, zero queued work, and zero
crafting. Without both retirement proof and physical quiescence, do not launch
the replacement. Preserve Sol, the one body/FIFO/write path, invalidate affected
state, and give the replacement latest structured state and the open milestone.
Record all interventions; assisted progress and timing are not benchmark proof.

Validate these scenarios against the schema offline, then exercise live
delivery/replacement only in an authorized supervised run:

| Scenario | Required result |
| --- | --- |
| Open goals, no active task, queue depth 0, crafting queue size 0 | Valid fresh evidence starts or continues the idle interval. Closed goals do not trigger intervention. |
| Active work, even with queue depth 0 | No idle claim or intervention; reset the prior interval. |
| Character crafting with no active task or queued plans | No idle claim; crafting queue size greater than 0 is work. |
| Parked waiting plan or predecessor-blocked queued plan, body still | Queue depth greater than 0 means pending work; no idle claim. Read status only with a known exact plan ID. |
| Repeated unchanged character samples while ticks/factory output advance | Retain the original idle timestamp. For an evidenced idle transition at 00:00, unchanged samples at 02:03 and 03:12 report 123 s and 192 s; they do not restart timing. |
| Unknown transition, first idle observation at 02:03 and unchanged sample at 03:12 | Report at least 69 s observed idle, not an exact start before 02:03. |
| Renewed movement, carried-inventory, task/queue, or crafting activity | Reset idle timing and nudge state; a later interval needs fresh evidence. |
| Missing, malformed, failed, stale observation, or run change | Invalidate timing; no intervention based on the uncertain interval. |
| Failed or uncertain exact-pilot message delivery | Record a capability problem, never successful nudge evidence; establish delivery state before retry. |
| Interrupted pilot without confirmed retirement, or unresolved physical call/work | No replacement writer starts. Obtain retirement proof, settle the call, and freshly prove all three idle fields first. |
| Confirmed retirement and fresh physical quiescence after five idle minutes | Record replacement intervention; preserve strategist/body/FIFO, invalidate affected state, and resume from latest structured evidence. |

Offline verification proves neither message delivery nor live
retirement/replacement. Claim live behavior only with an authorized supervised
validation and confirmed delivery and retirement receipts.

The native `/goal` owns continuation. Waypoints, batches, plans, and progress
reports are nonterminal. While later-tick milestone proof is absent, immediately
continue whenever productive work or bounded recovery exists. Keep the current
plan and one grounded successor when safe, and end the turn at report
checkpoints with work queued; native goal continuation starts the next batch.
Growth, automation, and packet-sizing policy lives in
`.agents/skills/factorio-player/SKILL.md`; a progress report states the measured
capacity change or quantitatively justifies a short manual bridge.

Exactly one physical MCP call may be in flight. Parallelize only read-only
observations when inconsistent ticks are acceptable, then revalidate the newest
state before mutation. Do not add another body, lane, RCON path, raw Lua/console,
teleport, hidden state, or free resources. `stop` is emergency cancellation, in the cases `AGENTS.md` lists.
If a pilot goal terminates after an intervention, retire it before starting one
replacement; never keep two pilots active.

Use the current public schema shown by `tools/list`. Keep the same persistent
pilot across packets. An empty intermediate turn or report does not satisfy the
goal and must not add another action writer.

Watch the run through the ordinary couch viewer client, which the mod makes a
characterless spectator that follows Codex, not through the native `Codex`
client window. The `Codex` client's own character is moved by the mod, and
Factorio client latency hiding mispredicts script-driven walking of a client's
own character, which shows as stutter and snapping on that window only. The
`Codex` client can stay minimized; it must remain connected. During a debug
run, keep the couch client log's `Latency changed to (N)` values below 60 ticks;
a spike to the 254-tick ceiling marks a long server tick.

## Historical Candidate B R7 verified live result

R7 ran the immutable baseline SHA-256
`616de9daf11ffdc03f946dd1f76732f4544539801f0f28db62959bcf8f1eea8e` with
deployed commit `80a5874eabc8d9822e7c8d24dd36b68ece4e26e6` and archive SHA-256
`d8d3600e4eb0a1d0087d1c9810070e514c4491c7abf05e63f01f14f58b3a2106`.
`GO` was `2026-09-03T06:26:52.063455112Z` at tick `23015`; the deadline was
`2026-09-03T06:46:52.065339056Z`. The last ordinary action completed at
`2026-09-03T06:46:24.228Z`, before the deadline. The first read-only frozen sample
completed at `2026-09-03T06:47:08Z` with `source_tick=95498`. No post-deadline
gameplay occurred, and the 15.9-second collection latency grants no grace
or attribution to the deadline.

The frozen sample recorded carried `iron-plate=40`, `copper-plate=10`,
`copper-ore=8`, and `wood=2`, plus `iron-plate=10` in furnace output. Queue
depth, active task, and crafting queue were respectively `0`, `null`, and `0`.
The pre-deadline inspection at `2026-09-03T06:46:16.362Z`, 35.7 seconds before
the cutoff, showed furnace output `iron-plate=9` and one active craft at
progress `0.73`; earlier completed extracts had already established 40 carried
plates. Thus the exact cutoff lower bound is 49 processed iron plates.
Accepted copper and iron drill-to-chest extraction, `copper-plate=10`, and
Electronics were proved before the deadline.

The tenth furnace plate and Steam Power are collection-confirmed. Passive
pre-cutoff processing makes them overwhelmingly likely to reflect work already
underway before the cutoff, but the late snapshot alone is not exact-deadline
proof. Retain 49 as the cutoff lower bound unless tighter master-ledger tick
attribution is established. This remains satisfactory automation-first progress
relative to R5/R6, not a completed rocket objective.

Residuals were manual tree-fuel travel, manual chest/furnace transfers, one
recovered trapped layout, and master ledger/message lag that caused stale
envelopes and false post-deadline attribution. General follow-up remains
state-driven: validate access and accepted output before scaling, use measured
utilization to select the next bottleneck, and derive snapshot attribution only
from authoritative timestamps, ticks, and frozen structured evidence. For a
mining drill, nil `drop_target` before production means runtime binding is still
unknown; a matching non-nil target becomes authoritative after first output.

Current commit `c56a5f5149f381fd0cc88860a24259f3f9b62e89` was published during
R7. It retains the live-proven geometry behavior and adds explicit
pending-first-output plus fueled `build_plan` waiting semantics, but it was not
deployed or benchmarked in R7. This result used no map-coordinate evidence,
fixed route or order, screenshot, raw console, or gameplay cheat.

## Prior verified 0.8.0 live result

- `doctor` passed the complete config, authenticated RCON, protocol, and mod
  checks on Linux Factorio 2.0.77. `connect_status` reported app/mod 0.8.0.
- One `connect_status` call took 109 ms and one radius-30 `observe_local` call
  took 244 ms, 352 ms together. The initial structured state was position
  `(37.5859375, -63.4765625)`, stone 4, and iron plate 2.
- One three-step `run_plan` took 24.392 seconds and completed 3/3: mine coal 5
  at `(37.5, -63.5)`, walk to `(43.5, -68.5)`, and mine iron ore 5 at
  `(43.5, -70.5)`. Its final observation reported position
  `(42.671875, -68.1171875)` and inventory coal 5, stone 4, iron ore 5, and
  iron plate 2.
- `inspect_entity` with `positions: [{x: 31, y: -56}]` took 2.114 seconds and
  reported a healthy stone furnace with status `no_ingredients` and coal 1 in
  its fuel inventory. A packet using obsolete `targets` was rejected by the
  schema before runtime.
- One smelting `run_plan` took 19.458 seconds and completed 3/3: insert iron ore
  5, wait for five iron plates in output, and extract iron plate 5. Its final
  observation reported position `(37.62890625, -63.37109375)` and inventory
  coal 5, stone 4, and iron plate 7.

Each plan was one bounded milestone packet and exactly one MCP call. The pilot
used the plan's final observation without a redundant read. These are completed
live results, not a claim of ongoing gameplay. Gameplay used no screenshots,
raw console, Lua, cheats, or teleportation.

Post-run screenshots are permitted only after the scored run is frozen and only
when structured MCP evidence is insufficient for review. Review all relevant
map areas where items or machines were placed, but treat images as
non-authoritative: they must not contribute coordinates, routes, tactics, or
durable knowledge, and they never support live perception, navigation,
targeting, placement choice, or action selection. Revalidate every finding that
could affect a later run through structured in-game MCP data. This permission
does not authorize couch GUI control or expand the Windows-MCP boundary.

## Observed two-machine setup

The following was verified during the September 2026 live run. Treat the LAN
addresses as runtime inputs, not permanent configuration: confirm them with
`ip address`/DHCP leases before each session.

- The Linux workstation hosted Factorio on its LAN address `192.0.2.117`
  and game UDP port `34197`.
- The couch PC was `COUCH-PC` at `192.0.2.119` and connected with
  Steam's Factorio launch argument `--mp-connect 192.0.2.117:34197`.
  `--connect-to-server` is not a valid Factorio argument.
- The Linux firewall must allow UDP `34197` from the trusted LAN. The tested
  rule was `ufw allow from 192.0.2.0/24 to any port 34197 proto udp`.
  Apply this only through the workstation's supervised firewall procedure;
  do not change router DHCP settings for this validation.
- The prior verified couch install used `agentic-companion_0.8.0.zip` in
  `%APPDATA%\\Factorio\\mods` and an enabled `agentic-companion` entry in
  `%APPDATA%\\Factorio\\mods\\mod-list.json` before joining. The verified couch
  ZIP matched the server archive hash, was enabled, and joined successfully.
- The server's RCON remains private and local: `127.0.0.1:19015`. It is not
  the address the couch client uses.
- Factorio dedicated-server process arguments contain the RCON secret. Never
  print or read full arguments through `ps` full args, `/proc` command-line
  data, WMI `CommandLine`, or an equivalent process-inspection surface. Verify
  health through user-service state, PID, executable basename, and `doctor`
  only, and keep all reported output secret-redacted.

After changing the repository build or mod, run setup again, confirm both
Factorio config files are mode `0600`, restart the dedicated server, and then
reconnect the couch client. A client left in Factorio's
`WaitingForUserToSaveOrQuitAfterServerLeft` state must be exited or its
Factorio process closed before Steam will launch a fresh connection. Wait for
`factorio.exe` to exit completely before replacing the ZIP: Windows briefly
retained a lock on the old archive during the verified rollout.

Before upgrading an existing 0.9.x save, stop the server and retain an exact
copy of both the save and its matching 0.9.x mod archive. Validate 0.19.5 on a
copy first. Rollback means stopping the server, restoring that paired save and
archive, and confirming the restored version through `doctor`; never open the
only rollback save with the newer mod.

An ordinary SSH `Start-Process` did not place Steam in the interactive console
session. The verified fallback used one limited, interactive, one-shot
Scheduled Task to launch Steam, then removed that task. Without screenshots,
confirm that the Factorio client process has `SessionId 1` and that its log
reaches `InGame`.

The couch display runs at `3840x2160`, and `scripts/launch-native-client.ps1`
renders the isolated client at that native 16:9 size. A recorder may downscale
the captured window to `1920x1080`, but it must fit the complete source without
cropping or enlarging a lower-resolution viewport. Before a timed recording,
verify the live Factorio client area, capture-source dimensions and aspect
ratio, crop/transform state, and representative framing. A non-black Factorio
frame alone is not sufficient evidence of usable framing.

## Viewer-only couch session

The exact `Codex` client must join first. Every other connected identity is
made characterless and placed in spectator mode by the mod; there is no second
body and no administrator or console step. The current mod makes each connected
spectator camera follow the sole Codex body automatically. Codex itself still
walks physically; only the characterless viewer camera follows. Confirm the
normal couch identity has no body or inventory and remains aligned with Codex
during a physical `walk_to` action.

## Prior-release 0.7.0 live evidence and known failure signatures

The successful observations below were collected before release 0.19.5. They
are historical 0.7.0 evidence and diagnostic guidance, not live validation of
0.19.5. Complete the fresh run above after installing 0.19.5 before recording a
current-release result.

- `doctor --json` is the quickest preflight: the historical run reported exact
  config shape/mode `0600`, authenticated RCON, protocol/mod v5, and mod/app
  0.8.0. A 0.19.5 run must instead report protocol v22 and mod/app 0.19.5.
- A fresh MCP process should be used after rebuilding the CLI. The tested
  sequence was `connect_status`, `observe_local`, then an exact-coordinate
  `mine`; the successful physical result increased Codex inventory and
  completed the task. `stop` is safe cleanup when a task is still active.
- If an action reports `empty response from the game` while `stop` can still
  see the task, restart the CLI from the build containing the RCON
  response-order fix, then retry. Do not assume that an empty response means
  the enqueue did not mutate state.
- Physical mining requires the selected entity to be updated before
  `mining_state` is enabled. A task that approaches indefinitely with no
  inventory gain indicates a stale mod build; reinstall the current archive
  and restart Factorio.
- The observed couch launch reached `InGame` and the server logged the join.
  A successful network join alone does not prove spectator mode; verify the
  controller in the Factorio UI as described above.

## Optional couch UI navigation layer

For semantic Windows UI navigation, the couch PC was tested with
[CursorTouch Windows-MCP 0.8.5](https://pypi.org/project/windows-mcp/0.8.5/).
This is an optional fallback for non-game couch UI, administration, or
reconnection steps that SSH cannot perform, alongside the existing
AutoHotkey-based `couch-ui` fallback. Neither UI path controls Factorio through
the Codex MCP server. The gameplay pilot remains MCP-text-only: Windows-MCP's
Screenshot capability must never be used for Factorio perception or play.

The tested deployment details are:

- Python 3.12 and `windows-mcp==0.8.5` installed for the Windows user.
- A per-user Scheduled Task named `windows-mcp-server`, running at logon with
  limited (non-elevated) privileges.
- Streamable HTTP bound only to `127.0.0.1:8000`; never expose this listener
  directly on the LAN. If remote use is needed, carry it through the existing
  authenticated SSH connection with a local port forward.
- Telemetry disabled with `ANONYMIZED_TELEMETRY=false` and an empty
  `POSTHOG_API_KEY`.
- The launcher passes this explicit UI-only allowlist:
  `Screenshot,Snapshot,Click,Type,Scroll,Move,Shortcut,Wait,WaitFor,DisplayInventory,App`.
  PowerShell, FileSystem, Registry, Process, Clipboard, Scrape, Notification,
  MultiSelect, and MultiEdit are excluded. Screenshot remains unavailable to
  the Factorio gameplay pilot regardless of this UI administration allowlist.

The installer rewrites `~/.windows-mcp/start-server.cmd`; apply the allowlist
to that launcher after installation and restart only the `windows-mcp-server`
task. If using `config.toml`, write it as UTF-8 without a BOM: Windows
PowerShell's default UTF-8 writer can otherwise cause `Invalid statement` at
startup. Verify with a local MCP `initialize`/`tools/list` request and confirm
exactly 11 tools before adding the server to a client.

The tested endpoint reported Windows-MCP 4.0.1 internally even though the
installed package was 0.8.5; use the package version for pinning and retain
the scheduled-task launcher as the source of the effective runtime options.
