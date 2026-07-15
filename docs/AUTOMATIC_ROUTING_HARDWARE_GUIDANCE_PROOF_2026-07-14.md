# Automatic Routing and Hardware Guidance Proof Ledger

Date: 2026-07-14 (America/Los_Angeles)

This PR has exactly two product goals. A row becomes `CONFIRMED` only when the
source trace, automated coverage, and live verification named below all exist.
Source inspection or unit tests without final-app behavior remain `PARTIAL`.

## Scope

| Goal | Product contract | Current status |
| --- | --- | --- |
| Better automatic model routing | Agents can explicitly choose `Automatic (on device)`. The persisted sentinel resolves to a concrete installed on-device chat model that has a compatible hardware verdict. Normal turns keep the current safe route for cache locality; media turns can upgrade before send. Automatic never chooses a cloud provider or a tight, too-large, unknown, embedding, AppleScript-only, image-generation, or non-MLX route. Manual model selection exits Automatic. | PARTIAL — implementation and tests in progress; final app proof pending |
| Clearer hardware guidance | Model selection surfaces distinguish physical unified memory from the smaller recommended local-model working-set budget. Picker rows, model detail, onboarding, download status, and agent settings use the same `GPUMemoryBudget` verdict as routing, and state that current free RAM is checked again at load time. | PARTIAL — implementation and tests in progress; final app proof pending |

## Required proof matrix

| Row | Source/automated evidence required | Live evidence required | Status |
| --- | --- | --- | --- |
| Text route | Policy tests exclude remote and unsafe candidates, choose the strongest compatible local route, and preserve the persisted Automatic sentinel | Fresh isolated app shows `Auto → <concrete model>` and returns a coherent answer | NOT YET VERIFIED |
| Multi-turn stability | Policy test proves a current compatible route wins over a gratuitous stronger switch | At least three related turns stay on the same route and produce coherent answers without raw protocol markers | NOT YET VERIFIED |
| Media upgrade | Policy and composer tests prove only modalities with a concrete compatible local route are advertised, and send-time resolution happens before request construction | Attach real supported media in the isolated app; observe the route upgrade and a concrete media-grounded answer. If this Mac has no safe media route, verify the control is honestly absent/rejected instead | NOT YET VERIFIED |
| No-cloud boundary | Policy tests include connected remote candidates and prove none can win Automatic | With a connected provider visible in the picker, Automatic still names an on-device route and records no remote request | NOT YET VERIFIED |
| Hardware wording | Formatting tests pin unified-memory, recommended-budget, estimated-working-set, and fit wording to `GPUMemoryBudget` | Visually inspect agent settings, local model picker, model detail/onboarding or download status; displayed numbers must agree across surfaces | NOT YET VERIFIED |
| Runtime safety | Existing load preflight remains the final current-free-RAM gate; this PR does not change memory limits, sampler defaults, cache topology, or model generation config | Monitor the selected local model load and generation for responsiveness and a bounded physical footprint; no beachball or hidden cloud fallback | NOT YET VERIFIED |

## Merge gate

Before merge: focused policy/settings/chat tests, full OsaurusCore tests, clean
Release build, isolated signed-app Computer Use proof, PR CI, merge, and
merged-main CI. The sidebar layout report and all other community issues are
explicitly outside this PR.
