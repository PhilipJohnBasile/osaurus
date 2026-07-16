# Automatic Routing and Hardware Guidance Proof Ledger

Started: 2026-07-14 (America/Los_Angeles)
Last updated: 2026-07-15 (America/Los_Angeles)

This PR has two product goals plus one settings-truth requirement. A row becomes `CONFIRMED` only when the
source trace, automated coverage, and live verification named below all exist.
Source inspection or unit tests without final-app behavior remain `PARTIAL`.

## Scope

| Goal | Product contract | Current status |
| --- | --- | --- |
| Better automatic model routing | Agents can explicitly choose `Automatic (on device)`. The persisted sentinel resolves to a concrete installed on-device chat model that has a compatible hardware verdict. Normal turns keep the current safe route for cache locality; media turns can upgrade before send. Automatic never chooses a cloud provider or a tight, too-large, unknown, embedding, AppleScript-only, image-generation, or non-MLX route. Manual model selection exits Automatic. | PARTIAL — source and focused Xcode tests complete; final app proof pending |
| Clearer hardware guidance | Model selection surfaces distinguish physical unified memory from the smaller recommended local-model working-set budget. Picker rows, model detail, onboarding, download status, and agent settings use the same `GPUMemoryBudget` verdict as routing, and state that current free RAM is checked again at load time. | PARTIAL — source and focused Xcode tests complete; final app proof pending |
| Memory Safety settings are truthful | UI preview, `/admin/cache-stats`, cache construction, and actual model loads use one Osaurus resolver. `No Automatic Limits (Dangerous)` removes mode-derived load, allocator, prefix, KV, concurrency, chat-send, materialized-load-refusal, flexible-eviction, and prefix-store percentage caps when the corresponding advanced fields are blank. Explicit user overrides remain in force; physical/Metal guidance remains visible, and engine/platform allocation failures are still possible. | PARTIAL — source and focused Xcode tests complete; live settings/load proof pending |

## Scope guard

- No model-family parser, template, sampler, generation-config, content-delta,
  or tool-JSON behavior changes belong in this PR.
- MXFP4 is not installed and is not a test target. The only Gemma controls are
  the installed MXFP8 and JANG_4M bundles. If the reported Gemma behavior does
  not reproduce in those controls, this PR makes no Gemma behavior change.
- The PR must not infer a fixed user RAM size. Host UI and routing read current
  `ProcessInfo.physicalMemory` plus Metal's advertised working-set value; tests
  use explicit synthetic values only where they are testing pure policy math.

## Required proof matrix

| Row | Source/automated evidence required | Live evidence required | Status |
| --- | --- | --- | --- |
| Text route | Policy tests exclude remote and unsafe candidates, choose the strongest compatible local route, and preserve the persisted Automatic sentinel | Fresh isolated app shows `Auto → <concrete model>` and returns a coherent answer | NOT YET VERIFIED |
| Multi-turn stability | Policy test proves a current compatible route wins over a gratuitous stronger switch | At least three related turns stay on the same route and produce coherent answers without raw protocol markers | NOT YET VERIFIED |
| Media upgrade | Policy and composer tests prove only modalities with a concrete compatible local route are advertised, and send-time resolution happens before request construction | Attach real supported media in the isolated app; observe the route upgrade and a concrete media-grounded answer. If this Mac has no safe media route, verify the control is honestly absent/rejected instead | NOT YET VERIFIED |
| No-cloud boundary | Policy tests include connected remote candidates and prove none can win Automatic | With a connected provider visible in the picker, Automatic still names an on-device route and records no remote request | NOT YET VERIFIED |
| Hardware wording | Formatting tests pin unified-memory, recommended-budget, estimated-working-set, and fit wording to `GPUMemoryBudget` | Visually inspect agent settings, local model picker, model detail/onboarding or download status; displayed numbers must agree across surfaces | NOT YET VERIFIED |
| Settings persistence | Store tests pin mode/slider round-trip, legacy implicit prefix-cap migration, true unlimited resolution, explicit-override preservation, and the no-limit switch used by Osaurus-owned gates | Change Safe Auto -> No Automatic Limits -> Safe Auto in the isolated app; save/reload each state and compare the visible resolved plan with `/admin/cache-stats.memory_safety` | NOT YET VERIFIED |
| Runtime setting effect | Source trace must show the same resolver feeding settings preview, diagnostics JSON, cache construction, `loadContainer` configuration, chat send severity, materialized-load refusal, flexible residency, and prefix-store policy | Unload between modes, load an installed control model, and observe the resolved load/allocator/KV/prefix/concurrency values change in diagnostics; no stale next-load-only state | NOT YET VERIFIED |
| Runtime safety | Existing current-free-RAM/load-pressure telemetry remains visible; this PR does not change sampler defaults, model generation config, parser behavior, or model templates | Monitor the selected local model load and generation for responsiveness and physical footprint; no beachball or hidden cloud fallback | NOT YET VERIFIED |

## Current execution status

- Branch `codex/auto-routing-hardware-guidance` is rebased directly onto merged
  Osaurus `main` at PR #2041 (`eaba91d05`).
- The cold SwiftPM command compiled and emitted `OsaurusCore`, then the SwiftPM
  test target stopped at the known configuration error `no such module
  'Testing'`. This is compile-only partial evidence, not a test pass.
- Both focused Xcode runs passed and executed their requested tests: routing,
  chat selection, hardware guidance, settings migration/resolution, agent,
  image, warmup, picker, model scan, and runtime-policy suites.
- After the exhaustive Memory Safety trace found the remaining chat-send,
  materialized-load-refusal, flexible-eviction, and prefix-store gaps, the
  OsaurusCore SwiftPM build completed again. Focused Xcode routing, hardware,
  settings, RAM-feasibility, and warmup tests passed. The first runtime-policy
  source run found two stale exact-string assertions after a function signature
  changed; after making those assertions signature-tolerant, the complete
  89-test `RuntimePolicySourceTests` suite passed serially. Current result:
  `/tmp/osaurus-routing-guidance-derived/Logs/Test/Test-OsaurusCoreTests-2026.07.15_19-11-14--0700.xcresult`.
- The full parallel OsaurusCore scheme is not green: 6,005 passed, 20 skipped,
  and 11 failed under shared global-state/timing contention. A serial rerun of
  all failing suites passed every failure except the local Gemma tokenizer
  assertion at `SwiftTransformersTokenizerLoaderTests.swift:701`. That test
  expects `capabilities_discover` in the Default-agent schema, while the current
  Default-agent source contract explicitly excludes discovery and exposes the
  consolidated `osaurus_*` configuration surface directly. This is a
  source-template control failure, not live inference evidence, and this PR has
  not changed either side of that contract.
- Next: inspect the final diff for scope, build an isolated Release app/bundle
  ID, and execute the full live rows above through Computer Use. The installed
  MXFP8/JANG_4M inference controls remain mandatory; MXFP4 remains out of scope.

## Merge gate

Before merge: focused policy/settings/chat tests, full OsaurusCore tests, clean
Release build, isolated signed-app Computer Use proof, PR CI, merge, and
merged-main CI. The sidebar layout report and all other community issues are
explicitly outside this PR.
