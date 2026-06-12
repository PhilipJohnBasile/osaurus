# DiffusionGemma Osaurus Integration

Date: 2026-06-12

## Current Source Truth

- Source bundle: `/Users/eric/models/google/diffusiongemma-26B-A4B-it`
- Hub repo: `google/diffusiongemma-26B-A4B-it`
- `model_type`: `diffusion_gemma`
- Architecture: `DiffusionGemmaForBlockDiffusion`
- Vision: `vision_config` present, `image_token_id = 258880`,
  `vision_soft_tokens_per_image = 280`
- Audio: `audio_config = null`, `audio_token_id = null`
- Video: processor metadata is present, but `video_token_id = null`

## Osaurus Boundary

This PR only teaches Osaurus capability surfaces about DiffusionGemma:

- `diffusion_gemma` is VLM-shaped for routing/discovery.
- DiffusionGemma model ids advertise image support.
- DiffusionGemma does not advertise audio or video support.

It does not claim runtime generation. Native block-diffusion text/VL generation
still belongs in vMLX: prompt encoder cache, denoising canvas, self-conditioning,
entropy-bound accept/renoise, and image soft-token preparation must be implemented
and live-proven before Osaurus should promote the row.

## Quant Dependency

The companion vMLX branch adds first-party quant prep/conversion scripts for:

- `/Users/eric/models/OsaurusAI/diffusiongemma-26B-A4B-it-MXFP4`
- `/Users/eric/models/OsaurusAI/diffusiongemma-26B-A4B-it-MXFP8`

Full conversion is blocked on local free space at the time of this note. The
downloaded BF16 source is 48 GB and the exact-shape estimates are about 14.85 GiB
for MXFP4 and 26.0 GiB for MXFP8.
