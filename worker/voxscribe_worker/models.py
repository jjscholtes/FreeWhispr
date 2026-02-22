from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any
import json
import time
import uuid


SCHEMA_VERSION = 1
PIPELINE_VERSION = "0.1.0"


def now_ms() -> int:
    return int(time.time() * 1000)


@dataclass
class WorkerError:
    code: str
    message: str
    details: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        data = {"code": self.code, "message": self.message}
        if self.details:
            data["details"] = self.details
        return data


@dataclass
class WordToken:
    startMs: int
    endMs: int
    text: str
    probability: float | None = None
    speakerId: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class TranscriptSegment:
    id: str
    startMs: int
    endMs: int
    speakerId: str | None
    text: str
    confidence: float | None = None
    speakerConfidence: float | None = None
    source: str = "machine"
    words: list[WordToken] | None = None

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        if self.words is not None:
            data["words"] = [w.to_dict() for w in self.words]
        return data


@dataclass
class Speaker:
    id: str
    defaultLabel: str
    displayName: str | None = None
    colorHex: str = "#111111"
    isUserEdited: bool = False

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class BackendInfo:
    name: str
    version: str | None = None
    model: str | None = None
    metadata: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        if self.metadata is None:
            data.pop("metadata")
        return data


@dataclass
class TranscriptDocument:
    sessionId: str
    speakers: list[Speaker]
    segments: list[TranscriptSegment]
    sourceLanguage: str | None = None
    transcriptionBackend: BackendInfo | None = None
    diarizationBackend: BackendInfo | None = None
    stats: dict[str, Any] = field(default_factory=dict)
    schemaVersion: int = SCHEMA_VERSION
    createdAt: int = field(default_factory=now_ms)
    updatedAt: int = field(default_factory=now_ms)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schemaVersion,
            "sessionId": self.sessionId,
            "createdAt": self.createdAt,
            "updatedAt": self.updatedAt,
            "sourceLanguage": self.sourceLanguage,
            "transcriptionBackend": self.transcriptionBackend.to_dict() if self.transcriptionBackend else None,
            "diarizationBackend": self.diarizationBackend.to_dict() if self.diarizationBackend else None,
            "speakers": [s.to_dict() for s in self.speakers],
            "segments": [s.to_dict() for s in self.segments],
            "stats": self.stats,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), ensure_ascii=False, indent=2)


@dataclass
class JobRequest:
    jobId: str
    sessionId: str
    audioPath: str
    outputDir: str
    languageMode: str = "auto"
    profile: str = "fast"
    asrModel: str = "turbo"
    diarizationEnabled: bool = True
    speakerHints: dict[str, int] | None = None
    wordTimestamps: bool = True
    mockMode: bool = False

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "JobRequest":
        return cls(
            jobId=str(payload.get("jobId") or uuid.uuid4()),
            sessionId=str(payload["sessionId"]),
            audioPath=str(payload["audioPath"]),
            outputDir=str(payload["outputDir"]),
            languageMode=str(payload.get("languageMode", "auto")),
            profile=str(payload.get("profile", "fast")),
            asrModel=str(payload.get("asrModel", "turbo")),
            diarizationEnabled=bool(payload.get("diarizationEnabled", True)),
            speakerHints=payload.get("speakerHints"),
            wordTimestamps=bool(payload.get("wordTimestamps", True)),
            mockMode=bool(payload.get("mockMode", False)),
        )


def envelope(message_type: str, request_id: str | None, command: str | None, payload: dict[str, Any]) -> dict[str, Any]:
    data = {"type": message_type, "payload": payload}
    if request_id is not None:
        data["requestId"] = request_id
    if command is not None:
        data["command"] = command
    return data

