import json
import importlib.util
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch
import sys

sys.dont_write_bytecode = True
WORKER_PATH = Path(__file__).parents[2] / "Resources/BarkWorker/bark_worker.py"
SPEC = importlib.util.spec_from_file_location("voiceploeg_bark_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


STANDARD_ID = "underdog-bark-3"
STANDARD = worker.VARIANTS[STANDARD_ID]


class WorkerTests(unittest.TestCase):
    def setUp(self):
        patcher = patch.object(worker.logging, "exception")
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        worker.MODEL = worker.MODEL_PATH = None

    def test_rejects_dutch_and_auto_before_loading_audio(self):
        worker.MODEL = object()
        for language in ("nl", "auto", None):
            payload, stop = worker.handle({"id": "abc", "command": "transcribe", "wavPath": "missing.wav", "language": language})
            self.assertEqual(payload["status"], "error")
            self.assertIn("English only", payload["error"]["message"])
            self.assertFalse(stop)

    def test_rejects_unpinned_repository_or_revision_before_download(self):
        for repo, rev in (("someone/another-model", STANDARD["revision"]), (STANDARD["repository"], "main")):
            with self.assertRaises(ValueError):
                worker.install_model(repo, rev, "/unused", "test", "test")

    def test_incomplete_installation_does_not_load_model(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "model.safetensors").write_bytes(b"partial")
            payload, stop = worker.handle({"id": "abc", "command": "loadModel", "path": directory})
        self.assertEqual(payload["status"], "error")
        self.assertIsNone(worker.MODEL)

    def test_all_variants_load_prepared_weights_offline(self):
        for model_id, variant in worker.VARIANTS.items():
            with self.subTest(model=model_id), tempfile.TemporaryDirectory() as directory, patch.dict(os.environ):
                for name in variant["installedFiles"]:
                    file = Path(directory, name)
                    file.parent.mkdir(parents=True, exist_ok=True)
                    file.touch()
                Path(directory, "installation.json").write_text(json.dumps({
                    "repository": variant["repository"], "revision": variant["revision"], "modelID": model_id}))
                with patch.object(worker, "load_prepared_model", return_value=object()) as load:
                    worker.load_model(directory)
                    load.assert_called_once_with(Path(directory).resolve())
                for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE"):
                    self.assertEqual(os.environ[key], "1")
                if model_id.endswith("-pro"):
                    self.assertFalse(Path(directory, "model.bark").exists())

    def test_rejects_manifest_with_another_variants_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "installation.json").write_text(json.dumps({
                "repository": STANDARD["repository"], "revision": STANDARD["revision"],
                "modelID": "underdog-bark-3-plus"}))
            with patch.object(worker, "load_prepared_model") as load:
                payload, _ = worker.handle({"id": "abc", "command": "loadModel", "path": directory})
            self.assertEqual(payload["status"], "error")
            load.assert_not_called()

    def test_long_recording_chunks_are_bounded_and_preserve_every_sample(self):
        class Wave(list):
            def __getitem__(self, index):
                result = super().__getitem__(index)
                return Wave(result) if isinstance(index, slice) else result
            def __pow__(self, power):
                return [x ** power for x in self]
        numpy = types.SimpleNamespace(mean=lambda values: sum(values) / len(values))
        wave = Wave([1.0] * 1200)
        wave[165:175] = [0.0] * 10
        with patch.dict(sys.modules, {"numpy": numpy}):
            chunks = list(worker.audio_chunks(wave, 10))
        self.assertEqual([value for chunk in chunks for value in chunk], wave)
        self.assertTrue(all(0 < len(chunk) <= 200 for chunk in chunks))
        self.assertLess(len(chunks[0]), 175)

    def test_corrupted_download_never_becomes_an_installed_model(self):
        def download(**kwargs):
            root = Path(kwargs["local_dir"])
            for name in STANDARD["files"]:
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b"corrupt")
        hub = types.SimpleNamespace(snapshot_download=download)
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, {"huggingface_hub": hub}):
            destination = Path(directory, "model")
            with self.assertRaisesRegex(ValueError, "verification failed"):
                worker.install_model(STANDARD["repository"], STANDARD["revision"], destination, STANDARD_ID, "test")
            self.assertFalse(destination.exists())
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_protocol_survives_unknown_command_and_shutdown_unloads(self):
        payload, stop = worker.handle({"id": "abc", "command": "nope"})
        self.assertEqual(payload["id"], "abc")
        self.assertEqual(payload["status"], "error")
        self.assertFalse(stop)
        worker.MODEL = object()
        payload, stop = worker.handle({"id": "def", "command": "shutdown"})
        self.assertTrue(stop)
        self.assertEqual(payload["status"], "ok")
        self.assertIsNone(worker.MODEL)


if __name__ == "__main__":
    unittest.main()
