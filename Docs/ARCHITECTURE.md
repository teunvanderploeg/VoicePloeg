# Architecture

## Recording lifecycle

`AppCoordinator` owns canonical UI state. Configuration and model preparation errors are separate from recording state. Capture ownership also has an explicit flag so configuration errors cannot bypass the recording limit or enable model maintenance during capture.

1. A menu action or registered Carbon shortcut requests recording.
2. The coordinator freezes the language, model and CLI configuration, checks Accessibility, verifies installed model files, and prepares the backend. This step never downloads models.
3. Microphone permission and input routing are checked before `AudioCaptureService` starts its AVAudioEngine.
4. Capture converts hardware-native audio to 16 kHz mono float samples and caps the buffer at two minutes. DC removal and peak normalization use a maximum gain of 16 to avoid amplifying background noise to full scale.
5. Stop restores the input route and creates an immutable `TranscriptionRequest`.
6. `SpeechTranscriptionService` routes the request to Whisper CLI, the persistent Crisper Python/PyTorch worker, or the persistent English-only Bark MLX worker.
7. Recognized text becomes the current transcript and is saved according to the history retention preference before editor insertion.

Experimental live dictation was rolled back. The current app uses stop-and-transcribe.

## Readiness and recovery

Missing or corrupt models and unavailable executables/runtimes fail before capture. Downloads are explicit settings actions. Auto has its own multilingual Whisper assignment and passes `-l auto`; English-only models cannot advertise Auto support. English, Dutch and Default assignments remain independent.

A failed transcription retains at most one recording in memory for Retry or Discard. Retry keeps the recovered transcript available to copy and respects the history preference. It does not insert into an editor whose focus may have changed. A successful transcription clears retained audio even if subsequent insertion fails. Starting a new capture or quitting discards retained audio.

Audio-engine configuration changes and input-device loss stop capture and retain the captured samples for recovery. The macOS application delegate joins transcription and clipboard delivery during termination, stops capture, restores input routing, and releases workers.

## Input routing

Preferences identify devices by CoreAudio UID and resolve the current numeric ID. `InputRouteController` journals the previous and temporary UIDs before changing the system default. It restores only while the system still uses VoicePloeg's temporary selection, preserving external user changes. The journal permits recovery after an interrupted session. Routing is still system-wide; app-scoped routing needs hardware validation before replacing this mechanism.

## Text output

Codex and ChatGPT composers use their paste handler. Other applications attempt Accessibility insertion before clipboard fallback. The original application must be verified before delivery. Accessibility messages have bounded timeouts. Clipboard transactions preserve all available items and types, leave the transcript available for one second after posting, and restore the old clipboard only when the user has not copied something else.

## Model and worker ownership

Whisper preloading reads the model into the filesystem cache. Each transcription still starts a new CLI process and initializes inference. Bark and Crisper retain a worker with loaded weights. Obsolete preparation is cancelled and joined before asset maintenance. Preparation errors are visible independently of recording errors. Idle workers unload after ten minutes; memory pressure and app termination also release them.

`OwnedSubprocess` uses a separate POSIX process group so cancellation and timeout stop descendants as well as the launcher. Exit polling uses nonblocking `waitpid`. Temporary process logs cannot fill an unread pipe. Worker requests are serialized, pipe writes suppress SIGPIPE, and acknowledged shutdown allows a bounded graceful exit before forced cleanup.

## Installation and integrity

Whisper downloads require HTTPS, exact size, and SHA-256 verification. Snapshot manifests identify model, repository, immutable revision, runtime version, and required files. New Bark and Crisper installations record installed file sizes and hashes. Crisper validates its model offline before publication. Existing snapshots without hashes retain compatibility but must pass identity, required-file, JSON, and safetensors-header validation; repair creates the stronger manifest.

Both Python runtimes install into a candidate relocatable environment. Imports are checked before publication and again at the final path. A previous installation remains available for rollback, including recovery from interrupted publication. Installation status is not ready until the manifest is committed. Inference forces Hugging Face and Transformers offline modes. Temporary audio directories are accessible only to their owner.

## Preferences and validation

`AppSettings` owns preferences. History can be off, retained for seven or thirty days, or kept until cleared, with a forty-entry cap. Expiration runs on launch, app activation, and history insertion. Individual deletion persists. Clear all transcripts also clears the current in-memory transcript.

SwiftPM and Xcode both compile in Swift 6 mode. Release preflight runs builds, tests, semantic catalog validation, Python worker tests, project generation, and unsigned Release packaging. The GitHub workflow runs the same preflight on macOS. Preparation, transcription, and delivery timings appear in Settings; the opt-in offline corpus test records normalization variants, recognition error, and model timings separately.
