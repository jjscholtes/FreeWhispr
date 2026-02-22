from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKER_SCRIPT = ROOT / "worker" / "voxscribe_worker.py"


def run_worker(command: str, payload: dict) -> list[dict]:
    line = json.dumps(
        {"type": "request", "requestId": "t1", "command": command, "payload": payload}
    )
    proc = subprocess.run(
        [sys.executable, str(WORKER_SCRIPT)],
        input=line + "\n",
        text=True,
        capture_output=True,
        check=True,
    )
    return [json.loads(raw) for raw in proc.stdout.splitlines() if raw.strip()]


class WorkerIPCTests(unittest.TestCase):
    def test_health_check(self) -> None:
        messages = run_worker("health_check", {})
        response = next(msg for msg in messages if msg.get("type") == "response")
        self.assertEqual(response["command"], "health_check")
        self.assertEqual(response["payload"]["status"], "ok")

    def test_mock_transcription_job_writes_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            payload = {
                "jobId": "33333333-3333-3333-3333-333333333333",
                "sessionId": "44444444-4444-4444-4444-444444444444",
                "audioPath": str(ROOT / "fixtures" / "audio" / "missing.wav"),
                "outputDir": td,
                "languageMode": "en",
                "profile": "fast",
                "asrModel": "turbo",
                "diarizationEnabled": True,
                "wordTimestamps": True,
                "mockMode": True,
            }
            messages = run_worker("run_transcription_job", payload)
            event_names = [
                msg["payload"].get("event")
                for msg in messages
                if msg.get("type") == "event" and isinstance(msg.get("payload"), dict)
            ]
            self.assertIn("job_progress", event_names)
            self.assertIn("job_completed", event_names)

            response = next(
                msg for msg in messages
                if msg.get("type") == "response"
                and msg.get("command") == "run_transcription_job"
                and msg.get("payload", {}).get("status") == "completed"
            )
            transcript_path = Path(response["payload"]["transcriptPath"])
            self.assertTrue(transcript_path.exists())
            self.assertTrue((Path(td) / "transcript" / "transcript.txt").exists())
            self.assertTrue((Path(td) / "processing" / "metrics.json").exists())


if __name__ == "__main__":
    unittest.main()

