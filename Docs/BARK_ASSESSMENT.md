# Underdog Bark 3.0 for VoicePloeg

Reviewed on 25 October 2026. Add Bark as an optional English backend and retain Whisper and CrisperWhisper for Dutch and other languages. Keep the existing default until representative dictation recordings have been compared.

This is Conway Research's speech recognition model, distinct from Suno's older text-to-audio model with the same name.

## Published accuracy

The publisher reports a seven-dataset English word error rate of 4.94% for Bark 3.0, compared with 6.04% for Whisper large-v3 and 6.58% for Whisper large-v3-turbo. Lower is better. These are publisher-reported Bark results using the Open ASR scoring code, rather than Bark entries independently evaluated on the leaderboard. The comparison does not establish accuracy against VoicePloeg's quantized Whisper models or CrisperWhisper. [Bark model card](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0)

Bark is English-only and preserves fillers and false starts. VoicePloeg offers the Standard, Plus, and Pro verbatim models as separate English selections. Bark Clean deliberately removes fillers and is a different model, which is not included. [Bark Clean model card](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Clean)

| Variant | Weight download | Publisher-reported English WER |
| --- | ---: | ---: |
| Bark 3.0 | 163 MB | 4.94% |
| Bark 3.0 Plus | 180 MB | 4.76% |
| Bark 3.0 Pro | 1.25 GB | 4.29% |

These publisher-reported averages do not guarantee the same ranking on an individual recording. Plus trades a slightly larger compressed download for a lower average error rate; Pro retains full BF16 weights. [Bark Plus comparison](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Plus)

## Measurements on the development Mac

The local test used the repository's 11-second JFK WAV, English, and the installed model files. macOS was 26.6.2 on Apple Silicon. The table records a sequential run after the release build, with no concurrent model benchmarks. These are single observations, not repeated statistical benchmarks.

| Model | Load | First transcription | Repeat transcription |
| --- | ---: | ---: | ---: |
| Bark 3.0, MLX, worker from release app bundle | 1.36 s | 0.35 s | 0.19 s |
| CrisperWhisper 2.0 medium, intended mode, MPS | 5.14 s | 2.79 s | 1.85 s |
| Whisper base.en q5_1, CLI | Included in call | 0.59 s | 0.60 s |
| Whisper large-v3-turbo q5_0, CLI | Included in call | 1.59 s | 1.60 s |

All four produced the expected words, with punctuation differences. This short, familiar recording cannot establish which model is more accurate for everyday dictation, accents, names, noise, or mixed-language speech. Initial compilation and filesystem caches affect first-use timings. The initial Bark run before caches were warm took 3.45 seconds for transcription. Bark and CrisperWhisper kept their models loaded between calls; Whisper started a new CLI process each time, as VoicePloeg does.

An earlier Bark diagnostic peaked at 1,306 MiB of worker memory. CrisperWhisper medium peaked at 2,504 MiB during the sequential comparison.

A 110-second repetition of the clip also completed with the application's pause-aligned segmentation. Bark took 1.99 seconds on the first transcription and 1.76 seconds on the repeat, with peak worker memory of 1,311 MiB. Repetition tests recording length and memory; it does not broaden the accuracy evidence.

## Integration and operating costs

Bark's compressed weights are 163,398,645 bytes. The installed FP16 safetensors are approximately 1.25 GB, with the compressed source retained as well. Runtime packages require additional storage. The reference loader describes roughly 6 GB of RAM for initial unpacking. The download is therefore smaller than our 574 MB quantized Whisper turbo, but larger than our 60 MB quantized Whisper base English. Download size does not describe inference memory. [Pinned reference loader](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0/blob/85db2ad18ab41e534a222ee253c29191d77ed919/bark_mlx.py)

VoicePloeg uses an isolated Python 3.12 environment with hashed dependencies and a separate pinned model revision for each variant. Standard remains pinned to `85db2ad18ab41e534a222ee253c29191d77ed919`; Plus uses `d4fab2f8b95681e5ad3cfb4e8c5f4e0c009b3deb` and Pro uses `4b5c51e04aa8d16dda9ecdff71bc29f7360149e4`. Model files have explicit sizes and SHA-256 hashes in `Resources/BarkWorker/bark-model-files.json`. Standard and Plus use the byte-identical bundled reference loaders. Pro uses the same tensor-name and layout conversion, preserving BF16 precision, and loads the same MLX Parakeet graph. Installation validates the weights before marking a model ready. Inference forces offline mode and never downloads executable model code. Switching models or responding to memory pressure releases the worker.

Recordings longer than 20 seconds are split at low-energy points near each window boundary. This bounds encoder memory but can change punctuation or recognition at a cut during continuous speech. The existing two-minute recording limit remains in force.

Bark's model license is CC BY 4.0. Attribution to Conway Research, NVIDIA, and Moondream appears in Settings and the bundled notice. [Upstream attribution](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0/blob/85db2ad18ab41e534a222ee253c29191d77ed919/NOTICE)

Run `Scripts/benchmark_bark_macos.py MODEL_DIRECTORY AUDIO.wav` with the Bark environment's Python to repeat the local diagnostic. Use recordings with reference transcripts before changing the default model.
