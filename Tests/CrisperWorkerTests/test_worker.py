import importlib.util
from pathlib import Path
import tempfile
import types
import unittest
import sys
from unittest.mock import patch

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
    def test_incomplete_download_preserves_previous_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "model"
            destination.mkdir()
            (destination / "previous").write_text("usable")

            def download(**arguments):
                (Path(arguments["local_dir"]) / "model.safetensors").write_bytes(b"")

            fake_hub = types.SimpleNamespace(snapshot_download=download)
            with patch.dict(sys.modules, {"huggingface_hub": fake_hub}):
                with self.assertRaises(RuntimeError):
                    worker.install_model("repo", "revision", destination, "model", "runtime")
            self.assertEqual((destination / "previous").read_text(), "usable")
            self.assertFalse((destination / "installation.json").exists())

    def test_offline_health_check_precedes_publish_and_manifest_has_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "model"

            def download(**arguments):
                for name in ["model.safetensors", "config.json", "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json"]:
                    (Path(arguments["local_dir"]) / name).write_bytes(b"test")

            fake_hub = types.SimpleNamespace(snapshot_download=download)
            with patch.dict(sys.modules, {"huggingface_hub": fake_hub}), patch.object(worker, "load_model") as load:
                worker.install_model("repo", "revision", destination, "model", "runtime")
            load.assert_called_once()
            import json
            manifest = json.loads((destination / "installation.json").read_text())
            self.assertEqual(len(manifest["files"]["model.safetensors"]["sha256"]), 64)
            self.assertEqual(manifest["files"]["model.safetensors"]["size"], 4)

    def test_failed_health_check_keeps_previous_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "model"
            destination.mkdir()
            (destination / "previous").write_text("usable")

            def download(**arguments):
                for name in ["model.safetensors", "config.json", "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json"]:
                    (Path(arguments["local_dir"]) / name).write_bytes(b"test")

            with patch.dict(sys.modules, {"huggingface_hub": types.SimpleNamespace(snapshot_download=download)}), \
                    patch.object(worker, "load_model", side_effect=ValueError("bad model")):
                with self.assertRaises(ValueError):
                    worker.install_model("repo", "revision", destination, "model", "runtime")
            self.assertEqual((destination / "previous").read_text(), "usable")

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
