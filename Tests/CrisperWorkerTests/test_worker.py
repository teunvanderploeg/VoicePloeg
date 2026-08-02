import importlib.util
from pathlib import Path
import tempfile
import types
import unittest
import sys

sys.dont_write_bytecode = True


WORKER_PATH = Path(__file__).parents[2] / "Resources" / "CrisperWorker" / "worker.py"
SPEC = importlib.util.spec_from_file_location("voiceploeg_crisper_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(worker)


class FakeModel:
    def transcribe(self, path, language, mode, word_timestamps):
        assert Path(path).is_file()
        assert language == "nl"
        assert mode == "intended"
        assert word_timestamps is False
        return types.SimpleNamespace(text="lokale tekst", duration=1.0, processing_time=0.2)


class WorkerTests(unittest.TestCase):
    def test_unknown_command_returns_error_without_stopping(self):
        payload, stop = worker.handle({"id": "abc", "command": "nope"})
        self.assertEqual(payload["status"], "error")
        self.assertFalse(stop)

    def test_intended_transcription_serializes(self):
        worker.MODEL = FakeModel()
        with tempfile.NamedTemporaryFile(suffix=".wav") as wav:
            payload, stop = worker.handle(
                {
                    "id": "abc",
                    "command": "transcribe",
                    "wavPath": wav.name,
                    "language": "nl",
                    "mode": "intended",
                }
            )
        self.assertEqual(payload["result"]["text"], "lokale tekst")
        self.assertFalse(stop)

    def test_shutdown_is_graceful(self):
        payload, stop = worker.handle({"id": "abc", "command": "shutdown"})
        self.assertEqual(payload["status"], "ok")
        self.assertTrue(stop)


if __name__ == "__main__":
    unittest.main()
