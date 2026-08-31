# Osaurus Run Center

Status: implementation plan
Owner: Osaurus
Foundation branch: `codex/run-center-foundation`

## Product goal

Make every meaningful Osaurus execution inspectable, steerable, recoverable,
and evidence-backed without creating a second execution mode.

Run Center is a projection over the systems Osaurus already trusts:

- `ChatSessionData` remains the canonical conversation record.
- `BackgroundTaskState` remains the live owner for detached and headless work.
- `SchedulerDatabase.agent_runs` becomes the durable cross-agent run ledger.
- Subagent feeds remain the live source for delegated child execution.
- `RunTrace` remains the detailed terminal transcript and tool audit artifact.
- `EvidenceReportRegistry` remains the typed projection over eval, benchmark,
  runtime, live-proof, provider, and custom evidence artifacts.

The removed Work Mode is an explicit architectural constraint. Run Center must
not add another inference loop, another tool protocol, another folder model, or
another source of transcript truth.

## What to borrow, and what not to

These are product and runtime patterns to adapt, not compatibility claims or
code-copy targets. The links are the primary sources used for the plan.

| Inspiration | Borrow for Osaurus | Guardrail |
| --- | --- | --- |
| [Codex desktop](https://learn.chatgpt.com/docs/environments/git-worktrees) | A stable task/run identity, managed worktree with reversible Local handoff, native diff review, and a first-class scheduled-task surface | Never auto-merge, push, delete dirty work, or treat review as proof |
| [Atomic Chat](https://github.com/AtomicBot-ai/Atomic-Chat) | Project/conversation trees, one OpenAI-compatible local endpoint across engines, launch presets for external agents, and adjacent artifact preview | The facade must always expose the resolved backend and must not become a silent fallback |
| [Agent Orchestrator](https://github.com/Untrivial-ai/agent-orchestrator/blob/main/docs/architecture.md) | Persist facts and derive the board; aggregate workspace, diff, preview, PR, CI, and review under one run; route changed lifecycle feedback to the owner | Only one controller may own a run at a time; orchestration remains the existing Chat/Agent path, not a revived Work Mode |
| [Goose](https://github.com/aaif-goose/goose/blob/main/documentation/docs/mcp/developer-mcp.md) | Visible session permission modes plus per-tool policy | Configured deny is a hard ceiling; children cannot exceed parent authority |
| [OpenCode](https://opencode.ai/v2/docs/permissions) | Ordered project-scoped permission rules and staged conversation/file undo-redo | Undo is local and best-effort; show the exact diff and never imply reversal of external side effects |
| [Hermes Agent](https://hermes-agent.nousresearch.com/docs/user-guide/desktop) | Interrupt-and-redirect, context composition telemetry, bounded curated memory plus factual session search, and progressively loaded skills | Never expose hidden reasoning, silently promote memory/skills, or resume until cancellation ownership settles |
| [MTPLX](https://github.com/youssofal/MTPLX) | One live model owner shared by app and clients; bounded session/cache identity; token rate, pressure, thermals, and request-forensics beside the run | Save tuning only when it beats the bound baseline; keep transcript, run, and runtime-cache identities distinct |
| [MLX core](https://github.com/ml-explore/mlx/blob/37c26e5755da637255d57ea34b4879196a485301/docs/src/usage/lazy_evaluation.rst) | Explicit submitted/synchronized/released completion boundaries and signature-keyed compiled-graph receipts | Do not synchronize per token or reuse a compiled graph across an inexact architecture/shape/dtype signature |
| [oMLX](https://github.com/jundot/omlx/blob/e008a66b4703bc77404dab30f8f898a117d49dfe/README.md) | Native-kernel integrity status, cache-aware continuous batching, and observable hot-RAM/cold-SSD block lifecycle | Generic fallback is a typed degraded row, never silently presented as the supported fast path; hybrid/media companion state is mandatory |
| [vMLX](https://github.com/osaurus-ai/vmlx-swift/blob/e025cd77c4adf7f1813d157ea0fbb6514f4e86f4/README.md#production-validation-standard) | Machine-readable architecture-bucket capability contracts covering first token, multi-turn cache, quantized coherence, stop/EOS, tools, reasoning, media, and streaming | A vMLX capability claim is necessary but does not replace exact-pin built-app Osaurus proof |
| [Ollama](https://github.com/ollama/ollama/blob/f96e7aa0513b9973a0ccc71be414c2ecb9d65b1a/docs/api/usage.mdx) | One terminal receipt with queue/load/compile/prefill/decode/drain/cache timing, stop reason, counts, and explicit residency TTL/unload state | Emit completion only after GPU/cache tails settle; unified-memory estimates do not replace physical-footprint proof |
| [llama.cpp](https://github.com/ggml-org/llama.cpp/blob/daef7b6874397a5a7c3d7e38b55e2ee0adf7da38/tools/llama-bench/README.md) | Reproducible parameter-sweep benchmarks with repetitions, variance, and machine-readable rows | Performance rows do not prove chat coherence, tools, reasoning, cancellation, or cache restore |
| [Unsloth](https://unsloth.ai/docs/basics/dynamic-3.0-ggufs) | Task-qualified quantization admission using held-out trajectory divergence, including explicit refusal for agentic workloads | Never rescue a bad artifact with hidden sampling, forced thinking, prompt coercion, or parser cleanup |

`Agent Orchestrator` is assumed to mean Untrivial's Mac desktop product, and
`Llama` to mean `llama.cpp`, because those best fit the supplied desktop/local
runtime list. Those identities should be confirmed before making compatibility
commitments. The public Atomic Chat project is assumed to be
`AtomicBot-ai/Atomic-Chat`.

## User-visible outcome

Each run has one stable identity and can be viewed through a board with these
derived lanes:

1. **Working** — created, queued, or running.
2. **Needs You** — waiting for clarification or approval.
3. **In Review** — execution finished but required evidence is missing,
   partial, blocked, or failed.
4. **Proven** — required evidence exists and every required row passed.
5. **Done** — execution completed and no proof contract was required.
6. **Failed** — failed, cancelled, or interrupted.

Lane placement is always derived from append-only events and evidence. The UI
cannot manually paint a run green.

## Durable run contract

A run record evolves the existing `agent_runs` row with optional links to:

- chat session
- project
- parent and root run
- agent and selected model
- title and goal/instructions
- workspace metadata and base revision (later phase)
- immutable recipe revision (later phase)

Each run also has an append-only event stream. Events carry a monotonically
increasing per-run sequence number so projection and replay are deterministic.
The row stores the stream's immutable replay baseline: `created` for new V2
runs, or the actual pre-event state captured while migrating a V1 row. This
prevents an altered first event from masquerading as legacy history. Retries
create a new run linked to the prior run; terminal runs never become active
again.

Proof obligations are declared by stable requirement identity. An observed
passing artifact cannot substitute for a missing requirement, so favorable
subsets never project `Proven`.

Review is an orthogonal requested/resolved gate. A completed execution with a
pending review remains `In Review`, even when its other evidence has passed.

## Delivery phases

### Phase 0 — Ledger and deterministic projection

- Evolve `SchedulerDatabase` without breaking existing schedule history.
- Add optional session/project/parent/root/model metadata to run rows.
- Add a sequenced append-only `run_events` table.
- Add a pure reducer for lifecycle, evidence classification, and board lanes.
- Preserve legacy rows that have no events.
- Add migration, replay, invalid-transition, and cascade-delete tests.

Exit gate: focused tests and the full OsaurusCore suite pass. No UI or runtime
behavior claim is made in this phase.

### Phase 1 — Capture every execution source

- Emit events from background dispatch, schedules, watchers, channels, HTTP,
  plugins, and user-started Chat turns.
- Link delegated child runs to parent/root runs.
- Capture queued, started, waiting, resumed, cancelled, interrupted, and
  terminal transitions exactly once.
- Recover non-terminal rows after relaunch as interrupted until an owning
  execution can prove it resumed.

Exit gate: deterministic lifecycle tests plus real Release-app cancellation,
clarification, relaunch, and parent/child proof.

#### Phase 1 ownership and capture contract

- `agent_runs.id` is the durable per-execution identity. Conversation/context
  ids may be reused by reattachment and are never substituted for a run id.
- `BackgroundTaskManager` is the sole lifecycle and terminal writer for an
  accepted background dispatch. Schedule, HTTP, plugin, watcher, channel, and
  delegation layers create dispatch intent; they do not duplicate terminal
  facts after the manager settles the run.
- A direct Chat turn owns its lifecycle only when it has no prebound background
  run. Detaching that Chat transfers visibility, not lifecycle ownership.
- Admission writes `created` and then `queued` or `started` before execution.
  Queue promotion writes exactly one `started`; clarification and approval
  write `waitingForInput` and `resumed`, never a second start.
- A child receives one immutable run id plus parent run, root run, parent
  session, and tool-call provenance at launch. The delegation bridge and
  background manager reuse that identity instead of minting competing rows.
- A spawned batch has one aggregate run and one child per caller-stable job.
  Caller job ids are provenance, not durable run ids. Each child retains its
  own truthful outcome; aggregate partial-success evidence cannot paint a
  failed child as successful.
- Soft redirect/steering is a progress/wait/resume milestone. Terminal
  `interrupted` is reserved for an ownerless non-terminal row recovered after
  relaunch.
- Cancellation does not become terminal until inference, tool work, cache
  serialization, residency restoration, allocator cleanup, and Metal/runtime
  ownership have settled. Restore failure is a failed run, not a successful
  cancellation.
- Runtime/cache phase telemetry is coalesced at semantic boundaries. Token
  chunks never become SQLite events, and process-wide cache deltas under
  concurrency cannot prove a per-child cache hit.
- Evidence is attached only after the artifact is durably available under a
  stable id. An in-memory registry entry or best-effort trace write is not a
  receipt.

Implementation order: admission/queue/start and recovery; direct Chat roots;
delegation provenance; batch aggregate/children; clarification and approval;
settled cancellation; semantic runtime milestones; durable evidence attachment.

Implemented capture checkpoint: background admission and queue promotion use a
single durable run identity; direct Chat creates a root only when no background
identity is prebound; terminal cancellation waits for engine settlement; and
launch recovery atomically interrupts ownerless nonterminal rows before new
work is admitted. Background clarification keeps that ledger-confirmed run and
root identity across UI/plugin continuation tasks and records exact-once
`waitingForInput`/`resumed` boundaries without minting another run. Direct Chat
clarification likewise keeps its admitted root nonterminal across the answer,
freezes the admitted model for the resumed segment, and closes only after the
continuation settles. Cancelling either a direct or background clarification
routes through its lifecycle owner and clears the prompt without fabricating a
resume event before cancellation. A soft redirect preserves the wait boundary
and durably saves its steering turn for the eventual real resume. Ordinary
in-memory subagents now allocate one child identity before preparation, admit
that exact identity only after authorization and runtime admission succeed,
bind the ledger-confirmed child/root while they execute, and fail closed if
durable admission is rejected. True agent delegation transfers lifecycle
ownership to `BackgroundTaskManager`, which reuses the prepared child identity
and rejects missing parent/root/session/original-tool provenance or a failed
ledger admission before it registers or starts the task. Batch children keep a
synthetic per-job tool-call id for feed and interrupt isolation while retaining
the original outer `spawn_batch` call as immutable provenance. `spawn_batch`
now admits one aggregate only after the final authority check, fails closed
before child execution when that admission is rejected, and rebases each
prepared child's parent/root lineage from the ledger-confirmed aggregate
receipt. Child run ids are allocated once and reused across both target
preparation passes; caller-stable job ids remain explicit provenance through
ordinary and delegated dispatch. Job ids are bounded to a safe ASCII contract,
and secret-shaped values are redacted from durable trigger payloads while the
original caller identity remains available to the in-memory result join.
Successful child/aggregate envelopes return their durable run ids for
correlation. The aggregate closes after the existing batch scheduler has
collected every child outcome and its batch-owned local residency
handoff/cleanup has returned. Its terminal status matches the public envelope
contract: partial results with at least one usable child remain a truthful
success with `partial_failure` metadata, all-cancelled is cancelled, and
all-failed is error. Aggregate, ordinary-child, and delegated-child terminal
write failures now change the caller-visible result instead of being hidden in
a log. Duplicate SQLite child admission is transactionally rejected without a
second child row or parent `childLinked` event.

This aggregate slice is deliberately `PARTIAL`: it records the aggregate and
one child per job that actually enters its execution owner. An accepted job
that is refused or cancelled by the batch scheduler before `SubagentSession`
or `BackgroundTaskManager` starts it does not yet have a queued durable child
row. Completing the stated one-child-per-stable-job contract requires held
reservations owned by those existing execution owners, including an explicit
held-launch transfer for true delegated agents; pre-admitting those rows in
`SpawnBatchTool` would create a competing lifecycle writer and is prohibited.
`BackgroundTaskManager` also performs post-terminal residency acceleration and
chat warm-up rearming in an asynchronous follow-up. A delegated child's
completion receipt does not yet prove that follow-up has settled, so complete
delegated cleanup ordering remains unproven and is part of the held-launch /
settled-cancellation work rather than this checkpoint.

Validation status for this checkpoint remains `PARTIAL` until its exact commit
passes the pinned Xcode 26.4.1 fork CI and the required Release-app parent/child,
cancellation, persistence, and relaunch proof. Local Swift parsing and diff
integrity pass; the local Xcode 27 beta focused-test build is blocked by the
pre-existing `ChatView` type-check timeout, so it is not counted as a test pass.

### Phase 2 — Read-only Run Center

- Add Run Center to native navigation without replacing Chat or Projects.
- Render board lanes from the reducer.
- Add run detail with conversation, child graph, events, tool activity,
  artifacts, traces, tests/evals, runtime settings, and resource telemetry.
- Add a global **Needs You** inbox.

Exit gate: live Release-app UI proof across navigation, persistence, relaunch,
and complete terminal-state settlement.

### Phase 3 — Safe controls

- Steer or answer a waiting run.
- Cancel live work through its existing owner.
- Retry as a new linked run.
- Fork conversation state without mutating the source run.
- Add optional managed Git worktrees with explicit creation, handoff, and
  recoverable cleanup. Never auto-merge or silently delete a worktree.

Exit gate: cancellation at every lifecycle phase, retry identity, worktree
isolation, dirty-tree preservation, and live UI proof.

### Phase 4 — Evidence receipts

- Bind evidence artifacts to runs.
- Record exact Osaurus/vMLX/MLX revisions, model bundle identity, resolved
  generation settings, tool and permission decisions, cache configuration,
  token rate, time to first token, physical footprint, and test/eval results.
- Export a stable machine-readable and Markdown receipt.

Exit gate: no `Proven` lane without every declared requirement and available
artifact. Missing token rate or physical-footprint proof remains blocked.

### Phase 5 — Durable recipes

- Promote Methods and schedules into immutable recipe revisions.
- Add agent, model, tool, condition, approval, eval, and output nodes.
- Add bounded loops, checkpoints, idempotency keys, pause/resume, and retry
  from a failed node.
- Keep conversation history separate from recipe definition.

Exit gate: restart/replay determinism, one-use approvals, bounded loops, and
raw evidence for every failed node.

### Phase 6 — Model Studio and interoperability

- Add explicit per-model aliases/profiles layered over bundle defaults.
- Add residency pin/TTL controls and hardware-fit/benchmark receipts.
- Add ACP client/server interoperability for external coding agents.
- Add controlled Method-to-Skill promotion with diff, replay, approval, and
  rollback.

Exit gate: settings provenance from bundle to resolved request, real model and
tool-use proof, and no silent backend/profile fallback.

## Non-negotiable acceptance rules

- Chat and agent execution remain one system.
- The event log is append-only; corrections are new events.
- A retry is a new run, never a resurrection of a terminal run.
- Terminal closure is compare-and-set and exactly once; repeating the same
  outcome is idempotent and a conflicting outcome is rejected.
- Board lanes are derived, not directly persisted.
- No run is `Proven` from source inspection, load-only results, or a favorable
  subset of a matrix.
- Existing generation defaults remain bundle-owned unless the user explicitly
  overrides them.
- No automatic merge, destructive worktree cleanup, or silent backend switch.
- Secret-shaped event messages and sensitive metadata are redacted before
  persistence.
- Event streams fail closed on gaps, malformed metadata, unknown event types,
  or invalid lifecycle transitions.
- Every user-facing phase receives focused tests, the applicable full suites,
  and a fresh isolated Release-app proof before release claims.

## Phase 0 acceptance matrix

| Contract | Deterministic proof |
| --- | --- |
| Legacy compatibility | Existing `agent_runs` rows load with optional metadata absent |
| Restart-safe migration | A partially applied V1 ledger reaches V2 without losing its rows |
| Stable identity | Session, project, parent, and root IDs round-trip |
| Relationship integrity | Child roots derive from an existing parent; orphan and contradictory links fail |
| Event ordering | Concurrent appends from separate database handles receive unique increasing sequences |
| Replay | The same ordered events always produce the same snapshot |
| Replay provenance | New and migrated streams retain an immutable original baseline |
| Terminal safety | A terminal run cannot transition back to active or rewrite its outcome |
| Evidence honesty | Required missing/unknown/partial/blocked/failed evidence never projects `Proven` |
| Review honesty | A requested review blocks `Done` and `Proven` until a resolved event exists |
| Corruption safety | Gaps, unknown events, and malformed payloads fail closed |
| Pagination safety | Same-second runs remain reachable through a stable composite cursor |
| Cascade cleanup | Deleting an agent removes its run events with its run rows |
| Schedule compatibility | Existing schedule history summaries remain unchanged |
