# Project Plan

## Problem & Goal
- **Problem**: Previous attempts to build a macOS transcription app failed due to setup complexity, backend/tooling tradeoffs, and speaker diarization reliability issues.
- **Goal (Outcome)**: Build a local-first macOS app that can record a conversation session and produce a timestamped transcript with speaker-separated segments (e.g., `Speaker 1`, `Speaker 2`) using Whisper-class models.
- **Why now**: Apple Silicon tooling for on-device Whisper is much stronger now (MLX/WhisperKit/whisper.cpp ecosystem), and pyannote's newer `community-1` diarization model improves speaker assignment and STT reconciliation.

## Users & Jobs-to-be-Done
- **Primary Persona**: macOS power user (solo builder / interviewer / meeting participant) who wants private local transcription with speaker labels.
- **JTBD**: "Help me record a conversation on my Mac and get an accurate, speaker-labeled transcript so I can review and share notes without sending audio to the cloud."
- **Pain Points**:
- Hard local setup for audio capture + ASR + diarization
- Diarization quality breaks trust ("who said what" is wrong)
- Long processing times / crashes on large models
- No easy way to correct speaker labels after transcription
- Privacy concerns with cloud transcription services

## Research Inputs & Best-Practice Notes (Web Review, Feb 22, 2026)
- **WhisperX** is the strongest open-source reference pipeline for multi-speaker ASR with word timestamps + diarization (Whisper + alignment + pyannote + VAD). It also explicitly documents macOS CPU usage and major limitations (overlap/diarization quality).
- **pyannote `community-1` (pyannote.audio 4.0)** is the current open-source diarization baseline and adds an "exclusive" diarization mode that simplifies STT timestamp reconciliation.
- **faster-whisper** remains a practical backend for speed/memory tradeoffs and supports INT8 CPU mode, word timestamps, and VAD filtering.
- **WhisperKit** and **whisper.cpp** are strong native Apple Silicon references for on-device transcription and real-time microphone workflows on macOS.
- **MLX Whisper model conversions** (`mlx-community`) are viable for Apple Silicon local inference and provide `large-v3` FP16 / quantized options.

## Scope
### In Scope
- macOS desktop app (local-first) that records a session from microphone input
- Post-session transcription pipeline using Whisper-compatible model(s)
- Speaker diarization with generic speaker labels (`Speaker 1`, `Speaker 2`, ...)
- Timestamped transcript view (segment-level minimum; word-level if feasible)
- Transcript editing basics:
- Edit text
- Reassign segment speaker
- Rename speakers
- Export transcript (`txt`, `srt`, `json`)
- Model/profile selection at user level (e.g., Fast / Best)
- Progress UI for model download/transcription/diarization stages
- Local storage for recordings and transcript artifacts
- Error handling for common failures (permissions, missing model, diarization auth/setup issues)

### Out of Scope / Non-goals
- Perfect diarization on overlapping speech
- Speaker identification by real names/voiceprints (beyond manual rename)
- Real-time diarized transcript while recording (v1 is post-session processing)
- Cloud sync, team sharing, SaaS backend
- Meeting bot integrations (Zoom/Meet/Teams)
- Translation, summarization, action-item extraction
- System audio capture/loopback in v1 (defer unless required)

## Requirements
### User Stories
- As a macOS user, I want to record a conversation session in one click so that I can transcribe it later.
- As a user, I want the app to transcribe locally so that my audio stays private.
- As a user, I want speakers separated in the transcript so that I can tell who said what.
- As a user, I want to rename and correct speakers so that the final transcript is usable.
- As a user, I want export formats I can reuse (`txt`, `srt`, `json`) so that I can share or process the transcript elsewhere.
- As a user, I want a fast/best quality option so that I can choose speed vs accuracy per session.
- As a user, I want clear progress/errors so that I know whether recording/transcription is working or how to recover.

### Acceptance Criteria
- Given first launch, when the user opens the app, then the app explains microphone permission and can request it.
- Given microphone permission is granted, when the user presses Record, then audio capture starts and elapsed time is visible.
- Given an active recording, when the user presses Stop, then the session is saved locally and queued for transcription.
- Given a completed transcription run, when processing finishes, then the user sees a timestamped transcript with speaker labels.
- Given a transcript segment, when the user edits text or changes speaker assignment, then the change persists locally.
- Given speaker labels `Speaker N`, when the user renames a speaker, then all associated segments update in the transcript UI.
- Given a processed session, when the user exports as `txt`, `srt`, or `json`, then the file is generated successfully with timestamps and speaker labels (where format supports it).
- Given a missing model or failed diarization setup, when processing starts, then the app surfaces a clear error with next-step guidance (not a silent failure).
- Given long audio (>30 min), when processing runs, then the UI remains responsive and shows stage-level progress (recording saved / transcribing / diarizing / exporting).
- Given an offline environment after models are installed, when the user processes a session, then transcription and diarization can run locally (subject to selected backend requirements).

## Success Metrics
- **Primary metric**: % of recorded sessions that complete end-to-end and produce an editable speaker-labeled transcript locally (no crash/hang).
- **Leading indicators**:
- Median time from "Stop" to transcript-ready (by session length bucket)
- % sessions requiring manual speaker correction
- Crash-free session rate during recording and processing
- Export success rate by format
- **Measurement window**: First 25-50 real sessions on target Mac hardware (developer dogfooding).
- **Baseline (if known)**: No stable baseline yet (previous attempts failed).

## Constraints & Assumptions
- **Constraints**:
- Must run on macOS (Apple Silicon target).
- Must use Whisper-family ASR (user preference), with support for high-quality models like `large-v3`.
- Local-first architecture is strongly preferred for privacy.
- pyannote diarization quality is improved but still imperfect; overlap remains a known challenge.
- pyannote.audio 4.0 / `community-1` introduces features that improve STT reconciliation, but adds Python/runtime dependency constraints.
- macOS app must handle microphone permissions and audio device failures gracefully.
- **Assumptions**:
- V1 can be post-session transcription (not live diarized captions).
- V1 can use generic speaker labels with manual rename/correction.
- Primary language is English first; multilingual support is a later extension.
- Typical sessions are 2-6 speakers and up to ~2 hours.
- User is willing to install/download local models (multi-GB assets) on first use.

## Risks
- **Backend integration risk**: Combining native macOS UI + local ASR + diarization may reintroduce dependency/runtime issues that caused previous attempts to fail.
- **Diarization trust risk**: Speaker attribution errors (especially overlap/backchannels) can make the transcript feel unusable without a correction UX.
- **Performance/thermal risk**: Large models may be slow or thermally heavy for long recordings; poor defaults could create a bad first impression.
- **Packaging risk**: Shipping Python/ML dependencies inside a macOS app bundle can be brittle.
- **Audio capture scope risk**: If the real use case requires system audio/meeting app capture (not just microphone), v1 scope may miss the user's immediate need.

## Prioritization
- **P0 (Must-have foundation)**:
- Session recording (mic), local file persistence, permission flows
- Job pipeline + progress/error states
- Transcript data model + local storage
- **P1 (Core user value)**:
- Whisper transcription backend integration
- Speaker diarization integration + transcript speaker labeling
- Transcript review/edit UI (text + speaker reassignment + rename)
- Export (`txt`, `srt`, `json`)
- **P2 (Quality & usability)**:
- Model/profile management (Fast/Best)
- Resume/retry failed jobs
- Batch import of existing audio files
- Performance instrumentation + benchmark screen/logs
- **P3 (Advanced)**:
- Real-time partial transcription during recording
- System audio / loopback capture
- Speaker identification / voiceprints

## Smart Tweak
- **Original scope**: Real-time recording + real-time speaker diarization + high-accuracy final transcript in a single v1 experience.
- **Smart tweak**: Ship v1 as "record first, diarize/transcribe after stop" with strong edit/rename workflow and clear speed/quality profiles.
- **Why it preserves value**: It still delivers the core outcome ("who said what and when") while removing the highest-risk real-time synchronization and streaming-diarization complexity.

## Open Questions (For Approval / Architect Handoff)
- Is microphone-only recording acceptable for v1, or do you need meeting/system audio capture in v1?
- Is English-first acceptable for v1?
- Do you want v1 to be fully offline after setup, or is optional cloud diarization fallback acceptable?

## References (online research used)
- OpenAI Whisper repo (model options, setup, `turbo` defaults): https://github.com/openai/whisper
- OpenAI `large-v3` release discussion (Nov 6, 2023): https://github.com/openai/whisper/discussions/1762
- OpenAI `large-v3-turbo` release discussion (Oct 1, 2024): https://github.com/openai/whisper/discussions/2363
- WhisperX (word timestamps + diarization + VAD, macOS CPU path, limitations): https://github.com/m-bain/whisperX
- faster-whisper (speed/memory/INT8/VAD/word timestamps): https://github.com/SYSTRAN/faster-whisper
- pyannote model docs (`community-1`, tradeoffs, speaker count controls): https://docs.pyannote.ai/models
- pyannote `community-1` blog (exclusive diarization mode for STT reconciliation): https://www.pyannote.ai/blog/community-1
- WhisperKit (native Apple Silicon on-device STT): https://github.com/argmaxinc/WhisperKit
- whisper.cpp (Apple Silicon + Metal/Core ML, mic streaming example, SwiftUI example): https://github.com/ggml-org/whisper.cpp
- MLX Whisper large-v3 model card (Apple Silicon MLX usage): https://huggingface.co/mlx-community/whisper-large-v3-mlx
- MLX large-v3 FP16/8-bit converted models (size/options): https://huggingface.co/mlx-community/whisper-large-v3-fp16 and https://huggingface.co/mlx-community/whisper-large-v3-8bit
