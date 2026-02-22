#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp/mock-session"
mkdir -p "$OUT"

python3 "$ROOT/worker/voxscribe_worker.py" <<EOF
{"type":"request","requestId":"c1","command":"run_transcription_job","payload":{"jobId":"22222222-2222-2222-2222-222222222222","sessionId":"11111111-1111-1111-1111-111111111111","audioPath":"$ROOT/fixtures/audio/missing.wav","outputDir":"$OUT","languageMode":"en","profile":"fast","asrModel":"turbo","diarizationEnabled":true,"wordTimestamps":true,"mockMode":true}}
EOF
