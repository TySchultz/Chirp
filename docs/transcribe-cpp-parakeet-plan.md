# transcribe.cpp + Parakeet v2 integration plan

## Outcome

Make Parakeet TDT 0.6B v2, running locally through `transcribe.cpp`, Chirp's
primary transcription engine. Keep Apple Speech available as an automatic
fallback so a model download, native backend, or model-load failure does not
make dictation unusable.

## Upstream pins

- Runtime: `handy-computer/transcribe.cpp` v0.1.3.
- Native Apple artifact: the official `TranscribeCpp.xcframework.zip` release
  asset, SHA-256
  `b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd`.
- Model: `parakeet-tdt-0.6b-v2-Q4_K_M.gguf` from the upstream
  `handy-computer/parakeet-tdt-0.6b-v2-gguf` repository.
- Model size: 475,491,840 bytes.
- Model SHA-256:
  `4853f9653f641d376e6f7de65d73c7a34a73677704a606727bf51acc83f999f3`.
- Runtime license: MIT. Model license: CC-BY-4.0.

Q4_K_M is selected because upstream reports nearly identical accuracy to Q8_0
(1.72% versus 1.69% WER on LibriSpeech test-clean) while reducing the model
download from roughly 730 MB to 483 MB. Both have effectively identical Metal
latency in the published M4 Max measurements.

## Architecture

1. Add a project-local Swift package that exposes a narrow Swift API over the
   official native XCFramework. The package pins the remote binary URL and
   checksum, initializes the backend, owns the native model/session handles,
   and converts native failures into `LocalizedError` values.
2. Add a `ParakeetModelStore` responsible for the Application Support model
   location, URLSession download, progress reporting, byte-count
   validation, SHA-256 verification, and atomic installation.
3. Add an actor-owned `TranscribeCppParakeetTranscriber`. It reuses one loaded
   model/session, pads non-empty recordings shorter than one second (behavior
   recovered from Chirp's former FluidAudio integration), and unloads after 30
   minutes idle to return Metal and memory resources.
4. Add a main-actor `TranscriptionManager` that exposes the observable state
   already consumed by Chirp. It tries Parakeet first and falls back to the
   existing Apple Speech transcriber for operational failures.
5. Continue feeding the engine Chirp's existing 16 kHz, mono, Float32 PCM. No
   resampling or file conversion is necessary.

## Download and failure behavior

- First launch starts preparing the model in the background and reports real
  download progress through the existing setup overlay.
- Downloads use a temporary file and only replace the final GGUF after both
  size and SHA-256 checks pass.
- A corrupt or partial final model is rejected and replaced on the next
  preparation attempt.
- If Parakeet preparation or transcription fails, the current recording is
  retried with Apple Speech. The Parakeet error remains visible in setup state
  and logs rather than silently pretending the primary engine is healthy.
- Recorded audio never leaves the Mac. Only the static model file is fetched.

## Verification

- Unit-test PCM conversion and short-audio padding.
- Unit-test normalized output and model metadata/path decisions without a
  network request.
- Resolve the local package and official binary artifact through Xcode.
- Build the Chirp app and run the unit-test target.
- Verify native ABI availability without requiring the 475 MB model download.
- When the model is locally present, perform an optional real transcription
  smoke test and confirm Metal is selected.

## Deliberate non-goals

- Live/streaming transcription. Parakeet TDT 0.6B v2 is an offline model and
  Chirp currently transcribes after recording stops.
- A model picker or multiple GGUF variants.
- Bundling the GGUF inside the app.
- Removing Apple Speech before the new path has real-world reliability data.
