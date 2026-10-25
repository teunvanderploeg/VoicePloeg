#!/usr/bin/env python3
"""Opt-in local Bark diagnostic. Run with the installed Bark runtime's Python."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model_path")
    parser.add_argument("audio_path")
    args = parser.parse_args()
    worker = Path(__file__).resolve().parents[1] / "Resources/BarkWorker/bark_worker.py"
    environment = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1")
    process = subprocess.Popen([sys.executable, str(worker), "--serve"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, text=True, env=environment)

    def request(command, **fields):
        payload = dict(id=str(uuid.uuid4()), command=command, **fields)
        started = time.perf_counter()
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        if response.get("id") != payload["id"] or response.get("status") != "ok":
            raise RuntimeError(response)
        return response.get("result", {}), time.perf_counter() - started

    try:
        _, loaded = request("loadModel", path=str(Path(args.model_path).resolve()))
        first, first_seconds = request("transcribe", wavPath=str(Path(args.audio_path).resolve()), language="en")
        second, warm_seconds = request("transcribe", wavPath=str(Path(args.audio_path).resolve()), language="en")
        request("shutdown")
        process.wait(timeout=10)
        print(json.dumps({"load_seconds": loaded, "first_seconds": first_seconds,
                          "warm_seconds": warm_seconds, "audio_seconds": second["duration"],
                          "warm_rtf": warm_seconds / max(second["duration"], 0.001),
                          "peak_worker_rss_mb": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024**2,
                          "text": first["text"]}, indent=2))
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
