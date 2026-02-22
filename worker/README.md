# FreeWhispr Worker

Local Python sidecar worker for transcription, diarization, transcript reconciliation, and exports.

## Development

- Python 3.11+ recommended
- Run locally:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r worker/requirements.txt
python worker/voxscribe_worker.py
```

## Notes

- The worker supports a deterministic mock pipeline for local UI development and tests when ML deps are unavailable.
- Hugging Face token is expected via `HF_TOKEN` or `HUGGINGFACE_HUB_TOKEN` for pyannote model access.
- The macOS app stores the Hugging Face token in Keychain and injects it into the worker process environment at launch.
- Use `../scripts/validate_real_worker.sh` to check `validate_setup` and optionally run a non-mock job from the command line.
