#!/usr/bin/env python3
"""Export the approved local artwork to macOS icon assets using Apple's tools."""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "Resources" / "Branding" / "VoicePloeg.png"
ASSET_SET = ROOT / "App" / "Assets.xcassets" / "AppIcon.appiconset"


def main():
    if not MASTER.is_file():
        raise SystemExit(f"Missing icon master: {MASTER}")
    ASSET_SET.mkdir(parents=True, exist_ok=True)
    images = []
    with tempfile.TemporaryDirectory(prefix="voiceploeg-icon-") as directory:
        iconset = Path(directory) / "VoicePloeg.iconset"
        iconset.mkdir()
        for size in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                filename = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                pixels = str(size * scale)
                destination = ASSET_SET / filename
                subprocess.run(
                    ["/usr/bin/sips", "-z", pixels, pixels, str(MASTER), "--out", str(destination)],
                    check=True, stdout=subprocess.DEVNULL,
                )
                (iconset / filename).write_bytes(destination.read_bytes())
                images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
        subprocess.run(
            ["/usr/bin/iconutil", "--convert", "icns", str(iconset), "--output", str(ROOT / "Resources" / "VoicePloeg.icns")],
            check=True,
        )
    (ASSET_SET / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print("Exported VoicePloeg app icon assets and Resources/VoicePloeg.icns.")


if __name__ == "__main__":
    main()
