from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "worker"))

from voxscribe_worker.exports import build_srt, build_txt, write_exports  # noqa: E402
from voxscribe_worker.models import BackendInfo, Speaker, TranscriptDocument, TranscriptSegment, WordToken  # noqa: E402
from voxscribe_worker.reconcile import SpeakerTurn, assign_speakers, build_transcript_document  # noqa: E402


class ReconcileExportTests(unittest.TestCase):
    def test_assign_speakers_by_overlap(self) -> None:
        segments = [
            TranscriptSegment(
                id="seg_1",
                startMs=1000,
                endMs=3000,
                speakerId=None,
                text="hello there",
                words=[
                    WordToken(startMs=1000, endMs=1800, text="hello"),
                    WordToken(startMs=1800, endMs=3000, text="there"),
                ],
            )
        ]
        turns = [SpeakerTurn(speakerId="spk_1", startMs=900, endMs=3100)]
        out = assign_speakers(segments, turns)
        self.assertEqual(out[0].speakerId, "spk_1")
        self.assertIsNotNone(out[0].speakerConfidence)

    def test_build_and_export_transcript(self) -> None:
        segments = [
            TranscriptSegment(id="seg_1", startMs=0, endMs=1500, speakerId=None, text="hello world"),
            TranscriptSegment(id="seg_2", startMs=2000, endMs=3400, speakerId=None, text="second line"),
        ]
        turns = [
            SpeakerTurn(speakerId="spk_1", startMs=0, endMs=1800),
            SpeakerTurn(speakerId="spk_2", startMs=1800, endMs=4000),
        ]
        doc = build_transcript_document(
            session_id="abc",
            segments=segments,
            turns=turns,
            detected_language="en",
            asr_backend=BackendInfo(name="mock-asr", model="turbo"),
            diar_backend=BackendInfo(name="mock-diar", model="community-1"),
        )
        txt = build_txt(doc)
        srt = build_srt(doc)
        self.assertIn("Speaker 1", txt)
        self.assertIn("-->", srt)

        with tempfile.TemporaryDirectory() as td:
            out = write_exports(doc, Path(td))
            self.assertTrue(Path(out["json"]).exists())
            self.assertTrue(Path(out["txt"]).exists())
            self.assertTrue(Path(out["srt"]).exists())
            parsed = json.loads(Path(out["json"]).read_text())
            self.assertEqual(parsed["sessionId"], "abc")


if __name__ == "__main__":
    unittest.main()

