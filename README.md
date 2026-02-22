# FreeWhispr (macOS Local Transcription Prototype)

Monochrome macOS transcription tool prototype for recording conversations and producing speaker-labeled transcripts locally.

## Current State

- SwiftUI macOS app with local recording + audio import, session shelf, folders, transcript editor, and export flow
- Python worker sidecar with JSONL IPC for transcription/diarization jobs
- Real-first local processing path (Whisper via `faster-whisper`, diarization via `pyannote`; mock path only for explicit dev overrides)
- Speaker naming/reassignment UI, session rename, move-to-folder, and delete actions
- Packaging scripts for bundled macOS app (`FreeWhispr.app` / `.zip`)
- Versioned JSON contract examples and basic tests for session store, exports, reconciliation, and worker IPC

## Repo Layout

- `app/` SwiftPM macOS app (`FreeWhispr`)
- `worker/` Python sidecar worker (`faster-whisper` + `pyannote` pipeline)
- `docs/contracts/` JSON contract examples
- `fixtures/` fixture data for tests/dev
- `scripts/` helper scripts (packaging, worker dependency install/validation, health checks, Swift test wrapper, icon build)

## Quick Start (UI)

```bash
cd app
swift run
```

The app defaults to real local processing. If worker dependencies/models or gated-model access are missing, setup validation and jobs fail with actionable errors instead of silently falling back to a mock pipeline.

## Quick Start (Worker)

```bash
python3 worker/voxscribe_worker.py
```

Send a command on stdin (JSONL), for example:

```json
{"type":"request","requestId":"1","command":"health_check","payload":{}}
```

## Real ML Setup

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

## Speaker Recognition (Speaker Separation) Setup - Step by Step

FreeWhispr can transcribe audio locally without extra account setup, but **speaker separation** (who said what) uses `pyannote` models hosted on Hugging Face and requires one-time access setup.

### 1. Install the local worker dependencies

From the project root:

```bash
./scripts/install_worker_deps.sh
```

This creates a local Python environment (`.venv313`) and installs the worker dependencies (including `faster-whisper` and `pyannote.audio`).

### 2. Start the app

Use the packaged app or run from source:

```bash
cd app
swift run
```

### 3. Open Settings in FreeWhispr

- Open **Settings**
- Go to **Diarization Setup** / **Model Access**
- Leave **Enable diarization by default** on (or toggle it on later per workflow)

### 4. Create a Hugging Face token (one-time)

Speaker separation uses gated `pyannote` models, so you need a Hugging Face account + token.

- Create or sign in to a Hugging Face account
- Generate an access token with **Read** access
- Copy the token

### 5. Request/accept access to the gated pyannote model (one-time)

Open the model page and request/accept access:

- `pyannote/speaker-diarization-community-1`

If Hugging Face prompts for terms/approval, complete that with the **same account** that created your token.

### 6. Paste the token into FreeWhispr

- In **Settings**, paste the token into **Hugging Face token (pyannote)**
- Click **Save settings**
- Click **Validate setup**

You want to see something like:

- `faster-whisper: available`
- `pyannote: available`
- `HF token: present`

### 7. Test speaker separation

- Record or import an audio file
- Make sure speaker separation/diarization is enabled
- Process the recording

The first run may take longer while models are downloaded/cached locally.

### 8. If it fails (common fixes)

**Error: `401 Cannot access gated repo ... pyannote/speaker-diarization-community-1`**

- Your token is present, but your account does not yet have access to the gated model
- Go back to the model page and make sure access was approved/accepted
- Confirm you used the same Hugging Face account for the token
- Re-run **Validate setup** and try again

**Error: `faster-whisper: missing`**

- Re-run:

```bash
./scripts/install_worker_deps.sh
```

- Restart the app and click **Validate setup** again

**Transcription works, but no speaker labels**

- Make sure diarization/speaker separation is enabled
- Very short clips or low-quality audio may produce weak speaker splits

**Microphone records silence**

- Check macOS permissions: **System Settings -> Privacy & Security -> Microphone**
- Allow access for **FreeWhispr**

### Notes

- The Hugging Face token is stored in the **macOS Keychain** (not in your transcript files).
- You can still use FreeWhispr without speaker separation by disabling diarization.
- Transcription and diarization run locally after the required models are installed and cached.

## Tests

```bash
./scripts/swift_test.sh
python3 -m unittest discover -s worker/tests -p 'test_*.py'
```

If `./scripts/swift_test.sh` reports an SDK/compiler mismatch, update/select a matching Xcode/Command Line Tools installation. The script already works around the local module-cache permission issue.
