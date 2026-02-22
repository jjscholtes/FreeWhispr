from __future__ import annotations

from pathlib import Path

from .models import TranscriptDocument


def _speaker_label_map(document: TranscriptDocument) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for speaker in document.speakers:
        mapping[speaker.id] = speaker.displayName or speaker.defaultLabel
    return mapping


def format_timestamp_srt(ms: int) -> str:
    hours = ms // 3_600_000
    minutes = (ms % 3_600_000) // 60_000
    seconds = (ms % 60_000) // 1000
    millis = ms % 1000
    return f"{hours:02}:{minutes:02}:{seconds:02},{millis:03}"


def format_timestamp_human(ms: int) -> str:
    hours = ms // 3_600_000
    minutes = (ms % 3_600_000) // 60_000
    seconds = (ms % 60_000) // 1000
    return f"{hours:02}:{minutes:02}:{seconds:02}"


def build_txt(document: TranscriptDocument) -> str:
    speakers = _speaker_label_map(document)
    lines: list[str] = []
    for seg in document.segments:
        label = speakers.get(seg.speakerId or "", "Unassigned")
        lines.append(f"[{format_timestamp_human(seg.startMs)}] {label}: {seg.text.strip()}")
    return "\n".join(lines).strip() + "\n"


def build_srt(document: TranscriptDocument) -> str:
    speakers = _speaker_label_map(document)
    entries: list[str] = []
    for index, seg in enumerate(document.segments, start=1):
        label = speakers.get(seg.speakerId or "", "Unassigned")
        entries.append(str(index))
        entries.append(f"{format_timestamp_srt(seg.startMs)} --> {format_timestamp_srt(seg.endMs)}")
        entries.append(f"{label}: {seg.text.strip()}")
        entries.append("")
    return "\n".join(entries).rstrip() + "\n"


def write_exports(document: TranscriptDocument, transcript_dir: Path) -> dict[str, str]:
    transcript_dir.mkdir(parents=True, exist_ok=True)
    json_path = transcript_dir / "transcript.json"
    txt_path = transcript_dir / "transcript.txt"
    srt_path = transcript_dir / "transcript.srt"

    json_path.write_text(document.to_json(), encoding="utf-8")
    txt_path.write_text(build_txt(document), encoding="utf-8")
    srt_path.write_text(build_srt(document), encoding="utf-8")

    return {
        "json": str(json_path),
        "txt": str(txt_path),
        "srt": str(srt_path),
    }


def write_json_export(document: TranscriptDocument, transcript_dir: Path) -> str:
    transcript_dir.mkdir(parents=True, exist_ok=True)
    json_path = transcript_dir / "transcript.json"
    json_path.write_text(document.to_json(), encoding="utf-8")
    return str(json_path)
