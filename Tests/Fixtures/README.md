# Dictation fixtures

`dictation-corpus.example.json` defines opt-in offline recognition cases. Paths resolve relative to that manifest. WAVs must be nonempty 16 kHz mono audio. Each case supplies its reference text, language, and an optional maximum word error rate.

The English fixture lives in the vendored Whisper sample directory. `synthetic-dutch.wav` was generated locally with macOS Xander on 25 October 2026 and converted to 16 kHz mono PCM. Its reference sentence is in the manifest. It contains no recorded user speech.

The test compares raw, normalized, and attenuated-then-normalized audio. These short integration fixtures do not represent speakers, accents, microphone hardware, noise, or everyday vocabulary. Add reference recordings through a separate corpus manifest before making recognition-quality decisions.
