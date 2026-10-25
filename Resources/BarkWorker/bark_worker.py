#!/usr/bin/env python3
"""VoicePloeg's local Bark MLX worker. Model code is bundled, never downloaded."""
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

os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["DO_NOT_TRACK"] = "1"
sys.dont_write_bytecode = True
logging.basicConfig(stream=sys.stderr, level=logging.INFO)
MODEL = None
MODEL_PATH = None
VARIANTS = json.loads(Path(__file__).with_name("bark-model-files.json").read_text())


def variant_for(repository, revision, model_id):
    variant = VARIANTS.get(model_id)
    if not variant or variant["repository"] != repository or variant["revision"] != revision:
        raise ValueError("Unsupported Bark model, repository or revision")
    return variant


def load_prepared_model(root):
    import mlx.core as mx
    from mlx_audio.stt import load
    model = load(str(root), strict=True, model_type="parakeet")
    mx.eval(model.parameters())
    return model


def prepare_pro_weights(root):
    """Convert published BF16 Transformers layouts to MLX, keeping BF16 weights."""
    import mlx.core as mx
    import numpy as np
    import bark_mlx
    source = mx.load(str(root / "model.safetensors"))
    # NumPy has no native BF16 representation. FP32 represents every BF16 value exactly.
    arrays = {name: np.asarray(value.astype(mx.float32)) for name, value in source.items()}
    converted = bark_mlx.to_mlx_names(arrays)
    weights = {name: mx.array(value).astype(mx.bfloat16) for name, value in converted.items()}
    prepared = root / "prepared.safetensors"
    mx.save_safetensors(str(prepared), weights)
    prepared.replace(root / "model.safetensors")
    shutil.copyfile(root / "mlx/config.json", root / "config.json")


def enable_offline_inference():
    for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE"):
        os.environ[key] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"


def load_model(path):
    global MODEL, MODEL_PATH
    root = Path(path).resolve()
    manifest = json.loads((root / "installation.json").read_text())
    variant = variant_for(manifest.get("repository"), manifest.get("revision"), manifest.get("modelID"))
    if not all((root / name).is_file() for name in variant["installedFiles"]):
        raise FileNotFoundError("Local Bark model is incomplete")
    enable_offline_inference()
    with contextlib.redirect_stdout(sys.stderr):
        MODEL = load_prepared_model(root)
    MODEL_PATH = str(root)


def transcribe(wav_path, language):
    if language != "en":
        raise ValueError("Bark supports English only")
    if MODEL is None:
        raise RuntimeError("No Bark model is loaded")
    started = time.perf_counter()
    with contextlib.redirect_stdout(sys.stderr):
        import numpy as np
        import soundfile as sf
        import bark_mlx
        wave, sample_rate = sf.read(wav_path, dtype="float32", always_2d=True)
        duration = len(wave) / sample_rate
        if duration > 120.1:
            raise ValueError("Bark recordings must be at most 120 seconds")
        # Bound encoder memory. Keep all words, with no overlap or deduplication.
        # Small pause-aligned windows avoid a quadratic attention allocation on 2-minute clips.
        wave = wave.mean(axis=1)
        texts = []
        for chunk in audio_chunks(wave, sample_rate):
            if len(chunk):
                texts.append(bark_mlx.transcribe(MODEL, np.asarray(chunk), sample_rate, pad_s=0.25))
    return {"text": " ".join(t for t in texts if t).strip(), "duration": duration,
            "processingTime": time.perf_counter() - started}


def audio_chunks(wave, sample_rate):
    """At most 20 seconds per chunk, cutting at a quiet 100 ms near the end."""
    import numpy as np
    start = 0
    limit = 20 * sample_rate
    while len(wave) - start > limit:
        search_start = start + 15 * sample_rate
        window = max(1, sample_rate // 10)
        candidates = range(search_start, start + limit - window + 1, window)
        cut = min(candidates, key=lambda i: float(np.mean(wave[i:i + window] ** 2))) + window // 2
        yield wave[start:cut]
        start = cut
    yield wave[start:]


def handle(request):
    global MODEL, MODEL_PATH
    request_id = str(request.get("id", "00000000-0000-0000-0000-000000000000"))
    command = request.get("command")
    try:
        if command == "loadModel":
            load_model(request["path"])
            result = {"path": MODEL_PATH}
        elif command == "transcribe":
            result = transcribe(request["wavPath"], request.get("language"))
        elif command in ("unloadModel", "shutdown"):
            MODEL = MODEL_PATH = None
            result = {}
        elif command == "health":
            import mlx.core
            import mlx_audio
            result = {"version": "3.0"}
        else:
            raise ValueError(f"Unknown command: {command}")
        return {"id": request_id, "status": "ok", "result": result}, command == "shutdown"
    except Exception as exc:
        logging.exception("Bark worker command failed")
        code = "out_of_memory" if "out of memory" in str(exc).lower() else "worker_command_failed"
        return {"id": request_id, "status": "error", "error": {"code": code, "message": str(exc)}}, False


def install_model(repository, revision, destination, model_id, runtime_version):
    variant = variant_for(repository, revision, model_id)
    from huggingface_hub import snapshot_download
    destination = Path(destination).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{destination.name}-download-", dir=destination.parent))
    try:
        snapshot_download(repo_id=repository, revision=revision, local_dir=temporary, allow_patterns=list(variant["files"]))
        if not all((temporary / name).is_file() for name in variant["files"]):
            raise RuntimeError("Downloaded Bark snapshot is incomplete")
        for name in variant["files"]:
            file = temporary / name
            expected = variant["files"][name]
            digest = hashlib.sha256()
            with file.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
            if file.stat().st_size != expected["size"] or digest.hexdigest() != expected["sha256"]:
                raise ValueError(f"Bark model verification failed: {name}")
        enable_offline_inference()
        with contextlib.redirect_stdout(sys.stderr):
            if variant["format"] == "transformers-bf16":
                prepare_pro_weights(temporary)
            else:
                import bark_mlx
                bark_mlx.HERE = str(temporary)
                prepared = temporary / "prepared"
                bark_mlx.prepare(str(temporary / "model.bark"), str(prepared), bits=16)
                for file in prepared.iterdir():
                    file.replace(temporary / file.name)
                prepared.rmdir()
            # Validate the local graph and weights before publishing installation.json.
            model = load_prepared_model(temporary)
            del model
        installed_files = {}
        for name in variant["installedFiles"]:
            file = temporary / name
            digest = hashlib.sha256()
            with file.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
            installed_files[name] = {"size": file.stat().st_size, "sha256": digest.hexdigest()}
        manifest = {"files": installed_files, "modelID": model_id, "repository": repository, "revision": revision,
                    "runtimeVersion": runtime_version, "installedAt": time.time()}
        (temporary / "installation.json").write_text(json.dumps(manifest, indent=2))
        backup = destination.with_name(f".{destination.name}-previous-{os.getpid()}")
        if destination.exists():
            destination.replace(backup)
        try:
            temporary.replace(destination)
        except Exception:
            if backup.exists():
                backup.replace(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--health", action="store_true")
    parser.add_argument("--install-model", action="store_true")
    for name in ("repository", "revision", "destination", "model-id", "runtime-version"):
        parser.add_argument(f"--{name}")
    args = parser.parse_args()
    if args.health:
        import constriction
        import mlx.core
        from mlx_audio.stt import load
        print("3.0")
        return
    if args.install_model:
        if not all((args.repository, args.revision, args.destination, args.model_id, args.runtime_version)):
            parser.error("Missing model installation argument")
        install_model(args.repository, args.revision, args.destination, args.model_id, args.runtime_version)
        return
    if not args.serve:
        parser.error("Choose --serve, --health, or --install-model")
    for line in sys.stdin:
        try:
            payload, stop = handle(json.loads(line))
        except Exception as exc:
            payload, stop = {"id": "00000000-0000-0000-0000-000000000000", "status": "error",
                             "error": {"code": "invalid_request", "message": str(exc)}}, False
        print(json.dumps(payload, separators=(",", ":")), flush=True)
        if stop:
            break


if __name__ == "__main__":
    main()
