#!/usr/bin/env python3
"""Opt-in local CrisperWhisper MPS diagnostic."""

import argparse
import os
import resource
import time


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("model_path")
    parser.add_argument("audio_path")
    parser.add_argument("--language", default="en")
    args = parser.parse_args()

    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

    from crisperwhisper import CrisperWhisperModel

    started = time.perf_counter()
    model = CrisperWhisperModel(
        args.model_path,
        backend="transformers",
        device="mps",
        compute_type="float16",
    )
    loaded = time.perf_counter()
    first = model.transcribe(args.audio_path, language=args.language, mode="intended")
    first_done = time.perf_counter()
    second = model.transcribe(args.audio_path, language=args.language, mode="intended")
    second_done = time.perf_counter()
    peak_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)

    print(f"load_seconds={loaded - started:.3f}")
    print(f"first_seconds={first_done - loaded:.3f}")
    print(f"warm_seconds={second_done - first_done:.3f}")
    print(f"audio_seconds={second.duration:.3f}")
    print(f"warm_rtf={(second_done - first_done) / max(second.duration, 0.001):.3f}")
    print(f"peak_rss_mb={peak_mb:.1f}")
    print(first.text)


if __name__ == "__main__":
    main()
