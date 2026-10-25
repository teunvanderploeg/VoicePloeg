#!/usr/bin/env python3
"""Local-only CrisperWhisper worker for VoicePloeg."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import logging
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
from typing import Any


logging.basicConfig(stream=sys.stderr, level=logging.INFO)
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("DO_NOT_TRACK", "1")
MODEL: Any | None = None
MODEL_PATH: str | None = None


def response(request_id: str, result: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"id": request_id, "status": "ok", "result": result or {}}


def error_response(request_id: str, code: str, message: str) -> dict[str, Any]:
    return {
        "id": request_id,
        "status": "error",
        "error": {"code": code, "message": message},
    }


def enable_offline_inference() -> None:
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_DATASETS_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"


def load_model(path: str, device: str, compute_type: str) -> None:
    global MODEL, MODEL_PATH
    model_path = Path(path).resolve()
    if not (model_path / "model.safetensors").is_file():
        raise FileNotFoundError(f"Local model is incomplete: {model_path}")

    enable_offline_inference()
    with contextlib.redirect_stdout(sys.stderr):
        from crisperwhisper import CrisperWhisperModel

        MODEL = CrisperWhisperModel(
            str(model_path),
            backend="transformers",
            device=device,
            compute_type=compute_type,
        )
    MODEL_PATH = str(model_path)


def handle(request: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    global MODEL, MODEL_PATH
    request_id = str(request.get("id", "00000000-0000-0000-0000-000000000000"))
    command = request.get("command")
    try:
        if command == "health":
            import crisperwhisper

            return response(request_id, {"version": crisperwhisper.__version__}), False
        if command == "loadModel":
            load_model(
                str(request["path"]),
                str(request.get("device") or "mps"),
                str(request.get("computeType") or "float16"),
            )
            return response(request_id, {"path": MODEL_PATH}), False
        if command == "transcribe":
            if MODEL is None:
                raise RuntimeError("No CrisperWhisper model is loaded")
            wav_path = Path(str(request["wavPath"])).resolve()
            if not wav_path.is_file():
                raise FileNotFoundError(f"Input WAV does not exist: {wav_path}")
            language = str(request.get("language") or "")
            if not language or language == "auto":
                raise ValueError("CrisperWhisper requires an explicit language")
            mode = str(request.get("mode") or "intended")
            started = time.perf_counter()
            with contextlib.redirect_stdout(sys.stderr):
                result = MODEL.transcribe(
                    str(wav_path),
                    language=language,
                    mode=mode,
                    word_timestamps=False,
                )
            processing_time = time.perf_counter() - started
            return response(
                request_id,
                {
                    "text": result.text,
                    "duration": float(result.duration),
                    "processingTime": float(
                        getattr(result, "processing_time", processing_time)
                    ),
                },
            ), False
        if command == "unloadModel":
            MODEL = None
            MODEL_PATH = None
            return response(request_id), False
        if command == "shutdown":
            MODEL = None
            MODEL_PATH = None
            return response(request_id), True
        return error_response(request_id, "unknown_command", f"Unknown command: {command}"), False
    except Exception as exc:  # Protocol boundary: errors must be returned, not crash stdout.
        logging.exception("Worker command failed")
        lowered = str(exc).lower()
        if "out of memory" in lowered and ("mps" in lowered or "metal" in lowered):
            code = "mps_out_of_memory"
        else:
            code = "model_load_failed" if command == "loadModel" else "worker_command_failed"
        return error_response(request_id, code, str(exc)), False


def serve() -> int:
    for raw_line in sys.stdin:
        try:
            request = json.loads(raw_line)
            payload, should_stop = handle(request)
        except Exception as exc:
            payload = error_response(
                "00000000-0000-0000-0000-000000000000",
                "invalid_request",
                str(exc),
            )
            should_stop = False
        sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        if should_stop:
            return 0
    return 0


def install_model(
    repository: str,
    revision: str,
    destination: Path,
    model_id: str,
    runtime_version: str,
) -> None:
    from huggingface_hub import snapshot_download

    destination = destination.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    for stale in destination.parent.glob(f".{destination.name}-download-*"):
        if stale.is_dir():
            shutil.rmtree(stale, ignore_errors=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{destination.name}-download-", dir=destination.parent)
    )
    try:
        snapshot_download(
            repo_id=repository,
            revision=revision,
            local_dir=temporary,
            allow_patterns=[
                "*.json",
                "*.safetensors",
                "*.txt",
                "*.model",
                "*.tiktoken",
            ],
        )
        required_files = ["model.safetensors", "config.json", "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json"]
        if not all((temporary / name).is_file() and (temporary / name).stat().st_size > 0 for name in required_files):
            raise RuntimeError("Downloaded Crisper snapshot is incomplete")
        # Loading entirely offline checks weights, tokenizer and configuration together.
        load_model(str(temporary), "mps", "float16")
        global MODEL, MODEL_PATH
        MODEL = MODEL_PATH = None
        files = {}
        for file in temporary.iterdir():
            if file.is_file():
                digest = hashlib.sha256()
                with file.open("rb") as source:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(block)
                files[file.name] = {"size": file.stat().st_size, "sha256": digest.hexdigest()}
        manifest = {
            "files": files,
            "modelID": model_id,
            "repository": repository,
            "revision": revision,
            "runtimeVersion": runtime_version,
            "installedAt": time.time(),
        }
        (temporary / "installation.json").write_text(
            json.dumps(manifest, indent=2), encoding="utf-8"
        )
        backup = destination.with_name(f".{destination.name}-previous")
        # Recover a previous interrupted publish before starting another replacement.
        if backup.exists():
            if not destination.exists():
                backup.replace(destination)
            else:
                shutil.rmtree(backup)
        if destination.exists():
            destination.replace(backup)
        try:
            temporary.replace(destination)
        except Exception:
            if backup.exists():
                backup.replace(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--health", action="store_true")
    parser.add_argument("--install-model", action="store_true")
    parser.add_argument("--repository")
    parser.add_argument("--revision")
    parser.add_argument("--destination")
    parser.add_argument("--model-id")
    parser.add_argument("--runtime-version")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.health:
        import crisperwhisper

        print(crisperwhisper.__version__)
        return 0
    if args.install_model:
        required = [
            args.repository,
            args.revision,
            args.destination,
            args.model_id,
            args.runtime_version,
        ]
        if any(value is None for value in required):
            raise SystemExit("Missing model installation argument")
        install_model(
            args.repository,
            args.revision,
            Path(args.destination),
            args.model_id,
            args.runtime_version,
        )
        return 0
    if args.serve:
        return serve()
    raise SystemExit("Choose --serve, --health, or --install-model")


if __name__ == "__main__":
    raise SystemExit(main())
