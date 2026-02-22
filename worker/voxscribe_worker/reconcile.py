from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

from .models import TranscriptSegment, WordToken, Speaker, TranscriptDocument, BackendInfo


@dataclass
class SpeakerTurn:
    speakerId: str
    startMs: int
    endMs: int


def overlap_ms(start_a: int, end_a: int, start_b: int, end_b: int) -> int:
    return max(0, min(end_a, end_b) - max(start_a, start_b))


def choose_speaker_for_span(start_ms: int, end_ms: int, turns: Iterable[SpeakerTurn]) -> tuple[str | None, float | None]:
    scores: dict[str, int] = {}
    total = max(1, end_ms - start_ms)
    for turn in turns:
        ov = overlap_ms(start_ms, end_ms, turn.startMs, turn.endMs)
        if ov <= 0:
            continue
        scores[turn.speakerId] = scores.get(turn.speakerId, 0) + ov
    if not scores:
        return None, None
    speaker_id, best_overlap = max(scores.items(), key=lambda item: item[1])
    ratio = best_overlap / total
    if ratio < 0.20:
        return None, ratio
    return speaker_id, ratio


def assign_speakers(
    segments: list[TranscriptSegment],
    turns: list[SpeakerTurn],
    low_conf_threshold: float = 0.45,
) -> list[TranscriptSegment]:
    for segment in segments:
        if segment.words:
            weighted: dict[str, int] = {}
            total_overlap = 0
            for word in segment.words:
                speaker_id, _ = choose_speaker_for_span(word.startMs, word.endMs, turns)
                word.speakerId = speaker_id
                if speaker_id is None:
                    continue
                ov = max(1, word.endMs - word.startMs)
                weighted[speaker_id] = weighted.get(speaker_id, 0) + ov
                total_overlap += ov
            if weighted:
                best_speaker, score = max(weighted.items(), key=lambda item: item[1])
                ratio = score / max(1, total_overlap)
                if ratio >= 0.20:
                    segment.speakerId = best_speaker
                    segment.speakerConfidence = ratio
                else:
                    segment.speakerId = None
                    segment.speakerConfidence = ratio
            else:
                segment.speakerId, segment.speakerConfidence = choose_speaker_for_span(segment.startMs, segment.endMs, turns)
        else:
            segment.speakerId, segment.speakerConfidence = choose_speaker_for_span(segment.startMs, segment.endMs, turns)

        if segment.speakerConfidence is not None and segment.speakerConfidence < low_conf_threshold:
            # Preserve assignment, but mark confidence low for UI review.
            segment.confidence = min(segment.confidence or 1.0, segment.speakerConfidence)
    return segments


def build_speakers(turns: list[SpeakerTurn]) -> list[Speaker]:
    ordered_ids: list[str] = []
    seen: set[str] = set()
    for turn in sorted(turns, key=lambda t: (t.startMs, t.endMs)):
        if turn.speakerId not in seen:
            seen.add(turn.speakerId)
            ordered_ids.append(turn.speakerId)
    return [
        Speaker(id=speaker_id, defaultLabel=f"Speaker {index + 1}")
        for index, speaker_id in enumerate(ordered_ids)
    ]


def build_transcript_document(
    session_id: str,
    segments: list[TranscriptSegment],
    turns: list[SpeakerTurn],
    detected_language: str | None,
    asr_backend: BackendInfo,
    diar_backend: BackendInfo | None,
) -> TranscriptDocument:
    assigned = assign_speakers(segments, turns) if turns else segments
    speakers = build_speakers(turns) if turns else []
    word_count = sum(len(seg.text.split()) for seg in assigned)
    duration_ms = max((seg.endMs for seg in assigned), default=0)
    stats = {
        "segmentCount": len(assigned),
        "speakerCount": len(speakers),
        "wordCount": word_count,
        "durationMs": duration_ms,
    }
    return TranscriptDocument(
        sessionId=session_id,
        speakers=speakers,
        segments=assigned,
        sourceLanguage=detected_language,
        transcriptionBackend=asr_backend,
        diarizationBackend=diar_backend,
        stats=stats,
    )

