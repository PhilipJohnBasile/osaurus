# Native-MTP allocator reuse ceiling evidence (2026-08-30)

## Status

`PARTIAL` until the exact integrated Osaurus Release app completes the served
and visible-Chat gates below. The direct runtime A/B is complete and isolates
the post-load allocator reuse policy without changing prompts, sampling,
reasoning, cache topology, model tensors, or MTP depth.

## Causal A/B

Both rows used the local
`JANGQ-AI/Qwen3.8-Flash-Next-JANG_2L` bundle, native MTP D3, greedy decoding,
the production 70% load budget, finite 65,536-token KV window, disk L2, and SSM
companion caching. The only changed value was MLX's persistent freed-buffer
reuse ceiling after load.

| Persistent reuse ceiling | Decode | Peak physical footprint | MTP result |
| --- | ---: | ---: | --- |
| 128 MiB | 50.3 tok/s | 50,371 MiB | D3, 222/223 D3 accepts, zero AR fallback |
| admitted 70% ceiling | 67.9 tok/s | 51,469 MiB | D3, 173/173 D3 accepts, zero AR fallback |

The admitted-ceiling row was 35% faster while its peak physical footprint was
only 1,098 MiB higher. Both rows recorded disk-L2 and SSM companion hits. The
Flash-Next PLE reader remained SSD-backed through `pread` with `F_NOCACHE`.

Raw logs:

```text
/Users/eric/vmlx-private-evidence/qwen38-auto-d3-20260830/2L-pr368-d3-persistent128m-count200.log
/Users/eric/vmlx-private-evidence/qwen38-auto-d3-20260830/2L-pr368-d3-persistent-admitted-count200.log
```

## Source contract

The runtime decision is based on the resolved decode path, not a bundle or
model-name allowlist:

- ordinary autoregressive models keep the configured Safe Auto allocator cap;
- resolved native MTP uses MLX's already-admitted memory ceiling;
- plain affine DeepSeek-V4 preserves its existing admitted-ceiling behavior;
- no resident model still resolves the cache limit to zero.

## Required integrated gates

1. Pin the bounded-window native-MTP vMLX head in Osaurus.
2. Build a Release app from the exact combined head.
3. Serve the count-to-200 prompt cold and warm; require native D3 counters,
   exact output, normal stop, disk-L2 plus SSM companion hits, token/s, TTFT,
   and physical footprint.
4. Drive the same app through visible Chat with one process, Auto selected,
   a tool call approved with **Always Allow**, tool-result continuation, a
   follow-up turn, and no terminal hang or marker leakage.
