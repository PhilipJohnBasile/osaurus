# Exact inference ownership and cancellation

Status: **PARTIAL — source and focused tests pass; Release-app live A/B pending.**

## User-visible defect

An external client could disconnect while local generation continued, and the
operator had no request-level view explaining whether the engine was loading,
queued, processing a prompt, generating, saving cache, or unloading. The old
HTTP disconnect hooks also called `cancelGeneration(name:)`, so one client
could cancel unrelated concurrent work using the same resident model.

## Causal source trace

- `HTTPHandler.runRequestTask` already owns an exact task per connection and
  cancels that task from `channelInactive`, input-close, idle-close, and
  `closeFuture`.
- Several streaming disconnect hooks bypassed that identity and additionally
  cancelled by model name.
- `ModelRuntime` already has one tracked producer wrapper per generation, but
  its identity, phase, producer source, and cancellation closure were not
  exposed to the UI.

## Fix contract

- One UUID per local model step.
- Exact producer attribution: Chat UI, HTTP API, Agent, Channel, Schedule,
  Watcher, Self-scheduled, Plugin, or P2P.
- Live phases: queued, loading, prompt processing, generation, cache save, and
  model unload.
- The Live Activity settings card lists active work and cancels only the
  selected request. Empty state is explicit.
- `/admin/cache-stats` exposes the same request IDs, sources, phases, start
  times, and cancellation state for CLI diagnostics.
- Agent display attribution is separate from residency ownership: delegated
  helpers remain chat-owned for handoff/reload correctness.
- HTTP disconnect relies on its exact route task and stream termination; no
  disconnect hook cancels by model name.

## Current automated evidence

- `InferenceActivityRegistryTests`: 3/3 pass.
- `RuntimePolicySourceTests.httpChannelCloseCancelsPerRequestStreamingTasks`:
  pass and pins the absence of model-name cancellation in `HTTPHandler`.
- Localization catalog/key/literal lint: pass.

## Required live gate before merge

Build Release from the exact PR head, confirm one app process and binary hash,
then run two simultaneous streams against one resident model. Disconnect A
mid-output and require B to finish coherently. Visually confirm Live Activity
shows the HTTP source and phase, its Stop button cancels exactly one selected
request, terminal/cache drain removes the row, and the empty state returns to
Idle. Preserve screenshots, app logs, request outputs, PIDs, binary SHA,
token/s, TTFT, footprint, and cache counters.
