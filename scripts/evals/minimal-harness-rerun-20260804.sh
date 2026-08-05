#!/usr/bin/env bash
# One-shot re-run of docs/MINIMAL_HARNESS_BENCHMARK.md (Osaurus vs Pi),
# 2026-08-04 regression check for the restored prompt-guidance contract.
# Baseline for comparison: PR #2250 benchmark status (2026-07-30) —
# Osaurus 23/31, Pi 0.83.0 5/12, bundle OsaurusAI/Bonsai-27b-1bit-JANG.
#
# Preconditions (per the doc): no Osaurus app instance, no other eval
# process, signed osaurus-evals binary (com.apple.security.virtualization).
set -uo pipefail

MODEL="${MODEL:-OsaurusAI/Bonsai-27b-1bit-JANG}"
API_MODEL="${API_MODEL:-bonsai-27b-1bit-jang}"
CONTEXT_WINDOW="${CONTEXT_WINDOW:-262144}"
MAX_TOKENS="${MAX_TOKENS:-8192}"
REPEAT="${REPEAT:-3}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVALS="${ROOT}/Packages/OsaurusEvals"
OUT="${EVALS}/build/minimal-harness/reliability-20260804"
BIN="${EVALS}/.build/debug/osaurus-evals"
mkdir -p "${OUT}"

log() { printf '[mhb] %s\n' "$*"; }

if pgrep -x osaurus >/dev/null 2>&1; then
  log "ERROR: an Osaurus app instance is running; quit it first (vmnet ownership)."
  exit 2
fi
if [[ ! -x "${BIN}" ]]; then
  log "ERROR: signed osaurus-evals binary missing at ${BIN}"
  exit 2
fi

cd "${EVALS}"

# ── Osaurus lanes (one process per suite, host-folder lanes first) ──
OSAURUS_EVALS_HARNESS=osaurus "${BIN}" run \
  --suite Suites/AgentLoop \
  --filter 'substantial-single-file-app|edit-one-key-preserve-others|recover-from-failing-command|workspace-escape-refused|cancel-after-two-calls-no-zombie' \
  --model "${MODEL}" --repeat "${REPEAT}" --out "${OUT}/osaurus-agent-loop.json"
log "osaurus-agent-loop done rc=$?"

OSAURUS_EVALS_HARNESS=osaurus "${BIN}" run \
  --suite Suites/AgentLoopFrontier \
  --filter 'long-horizon-project' \
  --model "${MODEL}" --repeat "${REPEAT}" --out "${OUT}/osaurus-frontier.json"
log "osaurus-frontier done rc=$?"

OSAURUS_EVALS_HARNESS=osaurus "${BIN}" run \
  --suite Suites/SandboxFrontier \
  --filter 'vm-host-isolation|vm-file-export' \
  --model "${MODEL}" --repeat "${REPEAT}" --out "${OUT}/osaurus-sandbox.json"
log "osaurus-sandbox done rc=$?"

# ── Pi lanes (need the Osaurus API; start/stop is manual per the doc) ──
if [[ "${SKIP_PI:-0}" == "1" ]]; then
  log "SKIP_PI=1 — stopping after the Osaurus lanes."
  exit 0
fi
if ! curl -sf "http://127.0.0.1:1337/v1/models" >/dev/null 2>&1; then
  log "ERROR: Osaurus API not reachable at 127.0.0.1:1337 — start it, then re-run with OSAURUS_ONLY skipped."
  exit 3
fi

PI_BIN="$(command -v pi)"

node "${ROOT}/scripts/evals/pi-harness-runner.mjs" \
  --pi "${PI_BIN}" --model "${MODEL}" --repeat "${REPEAT}" \
  --api-model "${API_MODEL}" \
  --osaurus-base-url http://127.0.0.1:1337/v1 \
  --context-window "${CONTEXT_WINDOW}" --max-tokens "${MAX_TOKENS}" --timeout-seconds 900 \
  --suite "${EVALS}/Suites/AgentLoop" \
  --filter 'substantial-single-file-app|edit-one-key-preserve-others|recover-from-failing-command|workspace-escape-refused|cancel-after-two-calls-no-zombie' \
  --out "${OUT}/pi-agent-loop.json"
log "pi-agent-loop done rc=$?"

node "${ROOT}/scripts/evals/pi-harness-runner.mjs" \
  --pi "${PI_BIN}" --model "${MODEL}" --repeat "${REPEAT}" \
  --api-model "${API_MODEL}" \
  --osaurus-base-url http://127.0.0.1:1337/v1 \
  --context-window "${CONTEXT_WINDOW}" --max-tokens "${MAX_TOKENS}" --timeout-seconds 900 \
  --suite "${EVALS}/Suites/AgentLoopFrontier" \
  --filter 'long-horizon-project' \
  --out "${OUT}/pi-frontier.json"
log "pi-frontier done rc=$?"

node "${ROOT}/scripts/evals/pi-harness-runner.mjs" \
  --pi "${PI_BIN}" --model "${MODEL}" --repeat "${REPEAT}" \
  --api-model "${API_MODEL}" \
  --osaurus-base-url http://127.0.0.1:1337/v1 \
  --context-window "${CONTEXT_WINDOW}" --max-tokens "${MAX_TOKENS}" --timeout-seconds 900 \
  --suite "${EVALS}/Suites/SandboxFrontier" \
  --filter 'vm-host-isolation|vm-file-export' \
  --out "${OUT}/pi-sandbox.json"
log "pi-sandbox done rc=$?"

# ── Matrix ──
"${BIN}" matrix "${OUT}" \
  --out "${OUT}/matrix.json" \
  --markdown "${OUT}/matrix.md"
log "matrix written to ${OUT}/matrix.md"
