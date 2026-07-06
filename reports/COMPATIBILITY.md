# Osaurus Model Compatibility (community)

> **Harness:** evals accuracy overhaul (2026-07). Re-run all rows with `EVALS_REPEAT=3`, a pinned strong judge (`JUDGE_MODEL` or `*_API_KEY`), and `make evals-contribute` before treating pass rates as publication-grade. Rows below were graded on the **pre-overhaul** catalog and are **not comparable** to post-overhaul runs until re-contributed.

| Field | Value |
| --- | --- |
| Catalog hash (frozen target) | _pending post-overhaul freeze_ |
| Harness repeat default | 3 (`scripts/evals/optimization-loop.sh`) |
| Judge policy | self-judge rubrics skipped; recorded runs require strong judge |

Crowdsourced from 6 contribution(s). Verdicts: **works** (runs cleanly), **partial** (runs with errors or low pass-rate), **broken** (error-dominated / never scored).

| Model | Verdict | Pass | Contrib | Chips | RAM band | peak RAM | decode tok/s | builds |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `Ornith-1.0-9B-MXFP4` | works | 76% (188/247) | 1 | Apple M4 Pro | 48GB | 20614MB | 23 | — |
| `gemma-4-12B-it-MXFP8` | works | 90% (223/247) | 1 | Apple M4 Pro | 48GB | 20536MB | 13 | — |
| `gemma-4-E4B-it-4bit` | works | 77% (188/245) | 1 | Apple M4 Pro | 48GB | 19798MB | 21 | — |
| `Qwen3-4B-4bit` | works | 80% (198/246) | 1 | Apple M4 Pro | 48GB | 20583MB | 53 | — |
| `Qwen3.5-4B-OptiQ-4bit` | works | 86% (212/247) | 1 | Apple M4 Pro | 48GB | 20487MB | 35 | — |
| `grok-4.3` | works | 92% (228/247) | 1 | Apple M4 Pro | 48GB | 19637MB | 10 | — |

## Caveats

- **Stale rows:** all six entries predate the harness/case overhaul — denominators and judge policy differ from new runs.
- `grok-4.3`: at least one contribution self-judged an LLM-judged suite — re-run with pinned `JUDGE_MODEL=xai/grok-4.3` (or another strong judge ≠ run model).
- `Ornith-35B`: blocked on load/RAM — document with evidence instead of omitting silently.

## Re-publish workflow

```bash
# Per model (strong judge + 3 trials + provenance):
export JUDGE_MODEL=xai/grok-4.3   # or anthropic/claude-sonnet-4-5, etc.
export EVALS_REPEAT=3
MODEL=<provider/model> make evals-contribute

# Rebuild leaderboard + validate provenance:
make evals-compat
VALIDATE=1 make evals-compat
```

See `reports/community/README.md` for contribution requirements and `scripts/evals/republish-compat.sh` for the full matrix.
