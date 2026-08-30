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
| 128 MiB | 51.5 tok/s | 50,017 MiB | D3, 173/173 D3 accepts, zero AR fallback |
| admitted 70% ceiling | 66.1 tok/s | 51,417 MiB | D3, 173/173 D3 accepts, zero AR fallback |

The admitted-ceiling row was 28% faster while its peak physical footprint was
only 1,400 MiB higher. Both rows recorded disk-L2 and SSM companion hits. The
Flash-Next PLE reader remained SSD-backed through `pread` with `F_NOCACHE`.
Both full outputs were byte-identical with SHA-256
`d4bcb44843ae465851740a4d3aaa34d91d1012271de0f7f0ceb87a980910c655`.
The Release `RunBench` binary SHA-256 was
`6d54ee3fac9c0066a0893118d1e9c1a435b6000b1f4986f7d4a23a6422f8f596`
at vMLX head `fe95824d84e34e38090a3df5610aaa3850ec2902`.

Raw logs:

```text
/Users/eric/vmlx-private-evidence/qwen38-auto-d3-20260830/2L-pr368-final-persistent128m-count200-spaces.log
/Users/eric/vmlx-private-evidence/qwen38-auto-d3-20260830/2L-pr368-final-persistent-admitted-count200-spaces.log
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
