#!/usr/bin/env bash
# Re-run all COMPATIBILITY.md models on the post-overhaul harness and rebuild
# the community leaderboard. Requires local MLX models and/or API keys.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -z "${JUDGE_MODEL:-}" ]] && [[ -z "${XAI_API_KEY:-}${ANTHROPIC_API_KEY:-}${OPENAI_API_KEY:-}${GEMINI_API_KEY:-}" ]]; then
  echo "error: set JUDGE_MODEL or a strong-judge *_API_KEY before publication re-run" >&2
  exit 1
fi

export EVALS_REPEAT="${EVALS_REPEAT:-3}"
export OSAURUS_EVALS_COMMIT="${OSAURUS_EVALS_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || true)}"

MODELS=(
  "Ornith-1.0-9B-MXFP4"
  "gemma-4-E4B-it-4bit"
  "mlx-community/Qwen3-4B-4bit"
  "mlx-community/Qwen3.5-4B-OptiQ-4bit"
  "OsaurusAI/gemma-4-12B-it-MXFP8"
  "xai/grok-4.3"
)

for model in "${MODELS[@]}"; do
  echo "[republish] contributing ${model} (repeat=${EVALS_REPEAT})"
  MODEL="$model" make evals-contribute
done

make evals-compat
VALIDATE=1 make evals-compat

echo "[republish] done — refresh reports/COMPATIBILITY.md catalog hash from matrix env block"
