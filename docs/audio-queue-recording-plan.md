# Audio Queue Recording Backend Plan

## Goal

Prototype an Audio Queue based input backend for Chirp to test whether it can reduce the current cold recording startup cost. The current AVAudioEngine path shows roughly 660 ms between `av_audio_engine_start_begin` and `av_audio_engine_start_returned` on the Studio Display Microphone. This plan keeps the user requirement that the macOS microphone indicator must not stay on after recording ends.

## Why Audio Queue Is Worth Testing

Apple describes Audio Queue Services as an Audio Toolbox API for recording and playback that connects to audio hardware, manages memory, and provides incoming audio packets through callbacks. It is lower-level than AVAudioEngine but higher-level than direct AUHAL, which makes it a good first prototype.

For Chirp, the hypothesis is:

- Audio Queue startup may avoid some AVAudioEngine graph setup overhead.
- Queue buffers can be allocated ahead of `AudioQueueStart` if doing so does not activate the mic indicator.
- The input callback can be kept small: copy PCM into our existing capture queue, re-enqueue the buffer, and let Chirp's existing processing path handle conversion, levels, draining, and transcription.

## API Shape

Use a small backend abstraction before writing the implementation so AVAudioEngine and Audio Queue can be compared behind a feature flag.

```swift
protocol AudioInputCaptureBackend: AnyObject {
  var onInitialCapture: (() -> Void)? { get set }
  var onCaptureFailure: ((Error) -> Void)? { get set }

  func prepare(inputDevice: AudioInputDevice?) throws
  func start() throws
  func stop(discardPendingAudio: Bool)
  func teardown()
}
```

For the first spike, avoid a broad refactor. The Audio Queue backend can call a new `AudioCapturePipeline.handle(samples:format:)` entry point, or it can wrap captured bytes in `AVAudioPCMBuffer` and reuse the existing `handle(buffer:)` path. Wrapping is slower but lower-risk for the first benchmark; a raw-sample path is better if Audio Queue wins.

## Proposed Implementation

Create `AudioQueueInputRecorder` as an internal class, initially compiled into the app but selected only by a debug feature flag such as:

```swift
UserDefaults.standard.string(forKey: "audioCaptureBackend") == "audioQueue"
```

Core state:

- `AudioQueueRef?`
- selected input device UID, if explicit
- input `AudioStreamBasicDescription`
- 3 to 4 `AudioQueueBufferRef` buffers
- `AudioCapturePipeline`
- atomic or locked state for recording generation, active/discarding flags, and first-capture latch

Setup flow:

1. Resolve device.
   - If Chirp is in automatic/default input mode, do not set a current-device property.
   - If an explicit non-default device is selected, use the device UID with `kAudioQueueProperty_CurrentDevice`.
2. Choose initial queue format.
   - Request linear PCM, Float32 if accepted.
   - Prefer native hardware sample rate where possible.
   - Convert/resample to 16 kHz off the callback thread, matching Handy's strategy and avoiding hardware sample-rate coercion.
3. Create the queue using `AudioQueueNewInputWithDispatchQueue` if the Swift block API behaves cleanly.
   - Fallback: use `AudioQueueNewInput` with a C callback and `Unmanaged<AudioQueueInputRecorder>`.
4. Allocate and enqueue 3 or 4 input buffers.
   - Start with 20 ms to 40 ms worth of frames per buffer.
   - Keep the callback work bounded: copy or move bytes, signal first capture, enqueue processing work, then re-enqueue.
5. Start with `AudioQueueStart`.
6. Stop with `AudioQueueStop`.
   - If the mic indicator remains off after stop, keep the queue prepared for reuse.
   - If the mic indicator remains on, dispose the queue immediately after stop.

## Startup Experiments

Run these variants on the same device and app build:

1. Cold create + allocate + start on hotkey.
2. Create + allocate on app launch, only call `AudioQueueStart` on hotkey.
3. Create + allocate after previous recording stop, keep idle queue for next recording.

For each variant, manually verify the macOS microphone indicator:

- after app launch
- after queue preparation but before start
- during recording
- immediately after stop
- 1 second after stop

If any idle/prepared state keeps the mic indicator on, reject that reuse mode.

## Instrumentation

Add `RecordingStartupTrace` events:

- `audio_queue_prepare_begin`
- `audio_queue_prepare_finished`
- `audio_queue_start_begin`
- `audio_queue_start_returned`
- `audio_queue_first_buffer_received`
- `audio_queue_stop_begin`
- `audio_queue_stop_returned`
- `audio_queue_disposed`

Keep the existing public log pattern so results can be compared directly with AVAudioEngine.

Primary metrics:

- hotkey to `AudioQueueStart` return
- hotkey to first input buffer
- hotkey to first UI waveform update
- stop to mic indicator disappearing
- captured sample count for short press-and-hold recordings

## Acceptance Criteria

Audio Queue should move forward only if it meets these conditions:

- Mic indicator is off whenever not recording.
- Median hotkey-to-first-buffer improves meaningfully over AVAudioEngine, target under 250 ms.
- No initial-capture timeout on default, Studio Display, and built-in microphones.
- Stop/drain preserves all queued audio for short recordings.
- Press-and-hold release during startup does not leak an active queue or stale buffers.
- Existing transcription tests remain green.

## Risks

- `AudioQueueNewInput` may still incur the same CoreAudio hardware startup cost as AVAudioEngine.
- Prepared queues may still hold the microphone open, which would violate the UX requirement.
- Swift callback ownership must be exact to avoid crashes or leaks.
- Device UID binding may reintroduce route-change churn if set unnecessarily.
- Input buffers may be interleaved, non-interleaved, Int16, or Float32 depending on accepted format.
- Bluetooth and display microphones may have larger first-buffer latency than built-in devices.

## Implementation Milestones

1. Add a private `AudioInputCaptureBackend` seam with AVAudioEngine still as default.
2. Build `AudioQueueInputRecorder` in isolation.
3. Add trace events and a debug flag to select the backend.
4. Run manual startup/mic-indicator benchmarks across devices.
5. If promising, replace the temporary AVAudioPCMBuffer wrapping with a raw PCM pipeline entry.
6. Harden route-change, default-device, and cancellation behavior.
7. Remove or keep the backend behind an experimental flag depending on measured results.

## References

- Apple: Audio Queue Services, https://developer.apple.com/documentation/audiotoolbox/audio-queue-services
- Apple: AudioQueueNewInput, https://developer.apple.com/documentation/audiotoolbox/audioqueuenewinput%28_%3A_%3A_%3A_%3A_%3A_%3A_%3A%29
- Apple: AudioQueueNewInputWithDispatchQueue, https://developer.apple.com/documentation/audiotoolbox/audioqueuenewinputwithdispatchqueue%28_%3A_%3A_%3A_%3A_%3A%29
- Apple: AudioQueueStart, https://developer.apple.com/documentation/audiotoolbox/audioqueuestart%28_%3A_%3A%29
- Apple: kAudioQueueProperty_CurrentDevice, https://developer.apple.com/documentation/audiotoolbox/kaudioqueueproperty_currentdevice
- Apple: Recording with Audio Queue Services overview, https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MultimediaPG/UsingAudio/UsingAudio.html
- Apple: Core Audio overview, https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatisCoreAudio/WhatisCoreAudio.html
