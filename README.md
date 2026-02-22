# FreeWhispr (macOS Local Transcription Prototype)

Monochrome macOS transcription tool prototype for recording conversations and producing speaker-labeled transcripts locally.

## Current State

- SwiftUI macOS app scaffold (recording, session shelf, processing state UI, transcript editor UI)
- Python worker sidecar with JSONL IPC
- Mock transcription/diarization pipeline for local development
- Versioned JSON contract examples
- Basic tests for session store, exports, reconciliation, and worker IPC

## Repo Layout

- `app/` SwiftPM macOS app
- `worker/` Python sidecar worker
- `docs/contracts/` JSON contract examples
- `fixtures/` fixture data for tests/dev
- `scripts/` helper scripts (health check, mock job, packaging, worker validation, Swift test wrapper)

## Quick Start (UI)

```bash
cd app
swift run
```

The app now defaults to real processing. If worker dependencies/models are missing, setup validation and jobs will fail with actionable errors instead of silently falling back to a mock pipeline.

## Quick Start (Worker)

```bash
python3 worker/voxscribe_worker.py
```

Send a command on stdin (JSONL), for example:

```json
{"type":"request","requestId":"1","command":"health_check","payload":{}}
```

## Real ML Setup (planned path)

- Install `worker/requirements.txt`
- In the macOS app, paste your Hugging Face token in `Settings -> Diarization Setup` (stored in macOS Keychain)
- CLI scripts can still use `HF_TOKEN` (or `HUGGINGFACE_HUB_TOKEN`) for worker-only validation
- Keep mock mode disabled (default). The mock path is only available for explicit developer CLI overrides.

Worker validation script:

```bash
./scripts/install_worker_deps.sh    # optional helper, creates .venv313 and installs worker requirements
./scripts/validate_real_worker.sh
# optional full job:
HF_TOKEN=... ./scripts/validate_real_worker.sh --python ./.venv313/bin/python3 --audio /path/to/sample.wav
```

## Tests

```bash
./scripts/swift_test.sh
python3 -m unittest discover -s worker/tests -p 'test_*.py'
```

If `./scripts/swift_test.sh` reports an SDK/compiler mismatch, update/select a matching Xcode/Command Line Tools installation. The script already works around the local module-cache permission issue.
