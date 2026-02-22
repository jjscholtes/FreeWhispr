#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
printf '%s\n' '{"type":"request","requestId":"health-1","command":"health_check","payload":{}}' | python3 worker/voxscribe_worker.py

