# Eval Matrix

- Generated: 2026-07-12T13:54:13.136Z

| Domain | Ornith-1.0-9B-MXFP4 | Ornith-1.0-9B-MXFP8 | foundation |
| --- | --- | --- | --- |
| agent_channels | — | — | 4/4 |
| agent_loop | 81/120 (skip 4) | 92/120 (skip 4) | — |
| apple_script | 23/33 (skip 2) | 25/35 | — |
| argument_coercion | — | — | 9/9 |
| cache_proof | 4/5 | 4/5 | — |
| capability_claims | 10/11 | 10/11 | — |
| capability_search | — | — | 16/17 (skip 2) |
| computer_use | — | — | 21/21 |
| computer_use_loop | 15/23 | 16/23 | — |
| default_agent | 15/28 | 26/27 (err 1) | — |
| http_api | 9/15 | 10/15 | — |
| judge_calibration | — | 11/11 | — |
| memory | 5/8 | 5/8 | — |
| micro_perf | 4/4 | 4/4 | — |
| prefix_hash | — | — | 9/9 |
| reasoning_channel | 4/13 | 3/12 (err 1) | — |
| sandbox_diagnostics | — | — | 12/12 |
| schema | — | — | 11/11 |
| screen_context | — | — | 22/22 |
| subagent | 45/45 (skip 2) | 44/45 (skip 2) | — |
| tool_envelope | — | — | 10/10 |
| tool_result_grounding | — | — | 10/10 |
| **total** | **215/305** | **250/316** | **124/125** |
| **chat-model** | 208/288 | 241/297 | 124/125 |
| **subsystem** | 7/17 | 9/19 | 0/0 |

## Performance

| Metric | Ornith-1.0-9B-MXFP4 | Ornith-1.0-9B-MXFP8 | foundation |
| --- | --- | --- | --- |
| decode tok/s (mean) | 27.4 | 22.9 | — |
| TTFT ms (mean) | 141 | 142 | — |
| peak RAM MB | 20610 | 20609 | 150 |
| CPU % (mean) | 85 | 74 | 109 |
| CPU % (peak) | 512 | 526 | — |
| ctx tok/task (mean) | 28929 | 27453 | — |
| total tok/task (mean) | 26798 | 24847 | — |

## Comparability

- ⚠ columns graded DIFFERENT case catalogs (Ornith-1.0-9B-MXFP4=8632f992dc0872b5, Ornith-1.0-9B-MXFP8=47bc36714bbf8db1, foundation=d7e06d8b7d2b4d4f) — totals mix denominators; only same-catalog columns compare 1:1

## Environment

- `Ornith-1.0-9B-MXFP4` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=8632f992dc0872b5
- `Ornith-1.0-9B-MXFP8` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=47bc36714bbf8db1
- `foundation` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=d7e06d8b7d2b4d4f
