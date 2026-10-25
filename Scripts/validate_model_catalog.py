#!/usr/bin/env python3
"""Validate model metadata before a build can ship an unusable catalog."""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import urlparse


def validate(items, strict_checksums=True):
    if not isinstance(items, list) or not items:
        raise ValueError("Model catalog must be a nonempty list")
    seen = set()
    for item in items:
        identifier = item.get("id", "")
        if not re.fullmatch(r"[a-zA-Z0-9_.-]+", identifier) or identifier in seen:
            raise ValueError(f"Invalid or duplicate model ID: {identifier}")
        seen.add(identifier)
        backend = item.get("backend", "whisperCpp")
        if backend not in {"whisperCpp", "bark", "crisperWhisper"}:
            raise ValueError(f"Unknown backend: {identifier}")
        if not isinstance(item.get("sizeBytes"), int) or item["sizeBytes"] <= 0:
            raise ValueError(f"Invalid model size: {identifier}")
        languages = item.get("languageSupport")
        if not isinstance(languages, list) or not languages or len(set(languages)) != len(languages):
            raise ValueError(f"Invalid languages: {identifier}")
        if "auto" in languages and (backend != "whisperCpp" or not {"en", "nl"}.issubset(languages)):
            raise ValueError(f"Invalid automatic language capability: {identifier}")
        if backend == "bark" and languages != ["en"]:
            raise ValueError(f"Bark must be English-only: {identifier}")
        if backend == "whisperCpp":
            if urlparse(item.get("downloadURL", "")).scheme != "https":
                raise ValueError(f"Invalid download URL: {identifier}")
            if strict_checksums and not re.fullmatch(r"[0-9a-fA-F]{64}", item.get("sha256", "")):
                raise ValueError(f"Missing or invalid SHA-256: {identifier}")
        else:
            if not re.fullmatch(r"[0-9a-f]{40}", item.get("revision", "")) or not item.get("repositoryID"):
                raise ValueError(f"Unpinned snapshot: {identifier}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", type=Path)
    parser.add_argument("--allow-unverified", action="store_true")
    args = parser.parse_args()
    validate(json.loads(args.catalog.read_text()), not args.allow_unverified)
    print("Model catalog validated")


if __name__ == "__main__":
    main()
