# AUHAL Recording Backend Plan

## Goal

Prototype a direct AUHAL input backend for Chirp to test the lowest-level native macOS capture path that still uses public Apple APIs. This is the most complex option, but it gives the most control over device selection, input callbacks, buffering, and conversion.

The user-facing requirement remains strict: the macOS microphone indicator must appear only while recording is active.

## Why AUHAL Is Worth Testing

Apple's Technical Note TN2091 documents capturing input from an audio device with the HAL Output Audio Unit, also called AUHAL. AUHAL sits on top of a HAL `AudioDevice` and can be configured for input by enabling input I/O, selecting a current device, setting the client format, registering an input callback, initializing, and starting.

For Chirp, the hypothesis is:

- AUHAL avoids AVAudioEngine graph overhead.
- We can configure exactly one input path with no additional nodes.
- We can use the device's native sample rate and resample off the realtime callback.
- We can benchmark several idle states to find out whether preconfiguration is possible without showing the mic indicator.

## Expected Architecture

Create `AUHALInputRecorder` behind the same backend protocol used for the Audio Queue spike:

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

Core AUHAL state:

- `AudioComponentInstance?` for the HAL output unit
- selected `AudioDeviceID`
- device ASBD from input scope, element 1
- client ASBD on output scope, element 1
- reusable `AudioBufferList` storage
- processing queue for non-realtime work
- recording generation and first-capture latch

## Proposed AUHAL Setup Flow

1. Create an Audio Component description:
   - `componentType = kAudioUnitType_Output`
   - `componentSubType = kAudioUnitSubType_HALOutput`
   - `componentManufacturer = kAudioUnitManufacturer_Apple`
2. Instantiate the unit with `AudioComponentInstanceNew`.
3. Enable input I/O:
   - set `kAudioOutputUnitProperty_EnableIO` to `1` on input scope, element 1
   - set `kAudioOutputUnitProperty_EnableIO` to `0` on output scope, element 0
4. Select the input device:
   - use Chirp's selected `AudioDeviceID`
   - if automatic/default mode, use `AudioInputDevice.currentDefaultInputDeviceID()`
   - set `kAudioOutputUnitProperty_CurrentDevice` after enabling I/O, matching TN2091 guidance
5. Read device format:
   - `kAudioUnitProperty_StreamFormat`
   - input scope, element 1
6. Set desired client format:
   - output scope, element 1
   - use the device sample rate for the first version
   - request linear PCM Float32
   - prefer non-interleaved if simple to bridge, otherwise accept interleaved and normalize in our processing queue
7. Register input callback:
   - `kAudioOutputUnitProperty_SetInputCallback`
   - callback calls `AudioUnitRender` to pull frames from output scope, element 1
8. Initialize with `AudioUnitInitialize`.
9. Start with `AudioOutputUnitStart`.
10. Stop with `AudioOutputUnitStop`.
11. Uninitialize or dispose depending on mic-indicator behavior.

## Callback Rules

The AUHAL callback runs on a realtime audio thread. It must not:

- allocate Swift arrays
- call async APIs
- lock heavily
- log every buffer
- run AVAudioConverter
- update SwiftUI

It should:

- call `AudioUnitRender`
- copy rendered bytes into a preallocated ring buffer or fixed pool
- signal first capture once
- enqueue minimal metadata to a processing queue
- return quickly

All conversion to mono, level calculation, resampling to 16 kHz, speech gain, and app-state updates should happen outside the callback.

## Startup Experiments

AUHAL has more lifecycle states than Audio Queue. We should benchmark all of these because the mic indicator behavior is the deciding constraint.

1. Cold instantiate + configure + initialize + start on hotkey.
2. Instantiate + configure at app launch, initialize + start on hotkey.
3. Instantiate + configure + initialize at app launch, start on hotkey.
4. After recording stop, call `AudioOutputUnitStop` only and keep the initialized unit.
5. After recording stop, call `AudioOutputUnitStop` + `AudioUnitUninitialize`, keep only the configured instance.
6. After recording stop, dispose the unit completely.

Manual mic-indicator checks:

- after component instantiation
- after enabling input I/O
- after setting current device
- after `AudioUnitInitialize`
- after `AudioOutputUnitStart`
- after `AudioOutputUnitStop`
- after `AudioUnitUninitialize`
- after `AudioComponentInstanceDispose`

If an idle initialized AUHAL keeps the indicator on, only the configured-but-uninitialized or fully disposed variants are acceptable.

## Instrumentation

Add trace events:

- `auhal_create_begin`
- `auhal_create_finished`
- `auhal_enable_io_finished`
- `auhal_device_selected`
- `auhal_format_resolved`
- `auhal_callback_registered`
- `auhal_initialize_begin`
- `auhal_initialize_returned`
- `auhal_start_begin`
- `auhal_start_returned`
- `auhal_first_render_received`
- `auhal_stop_begin`
- `auhal_stop_returned`
- `auhal_uninitialize_returned`
- `auhal_disposed`

Important measured intervals:

- hotkey to `AudioOutputUnitStart` return
- hotkey to first successful `AudioUnitRender`
- stop to callback silence
- stop to mic indicator disappearing
- drain time and lost-buffer count

## Acceptance Criteria

AUHAL should replace or compete with AVAudioEngine only if:

- Mic indicator is off whenever Chirp is not recording.
- Median hotkey-to-first-render is clearly below AVAudioEngine, target under 200 ms.
- No buffer allocation or conversion happens in the realtime callback.
- Device selection works for automatic/default and explicit devices.
- Route changes and device disconnects fail cleanly or recover at least as well as the current implementation.
- Short press-and-hold recordings preserve all captured audio.
- Existing tests remain green.

## Risks

- AUHAL is significantly more complex than Audio Queue.
- The callback and buffer ownership model is easy to get subtly wrong in Swift.
- `AudioUnitInitialize` may itself activate the microphone, limiting how much work can be done before the hotkey.
- Apple's TN2091 notes that changing formats can be disruptive and that device sample rate should match desired sample rate; we should avoid forcing 16 kHz at the AUHAL layer.
- Some USB/display/Bluetooth devices have separate input and output device objects or unusual channel layouts.
- The first implementation may need Objective-C or C helper code to keep pointer lifetimes and callback code simple.

## Implementation Milestones

1. Build a standalone `AUHALInputRecorder` spike, initially not wired to production settings UI.
2. Keep the desired format at the hardware sample rate and Float32 PCM.
3. Implement a fixed buffer pool or lock-free-ish ring buffer for callback handoff.
4. Add a debug backend flag: `audioCaptureBackend = auhal`.
5. Benchmark cold and preconfigured variants with mic-indicator checks.
6. Add route-change and default-device handling.
7. If the benchmark is strong, move mono conversion/resampling into a shared lower-level pipeline and retire the AVAudioPCMBuffer wrapping path.
8. If benchmark gains are small, keep AUHAL as documentation only and prefer the simpler Audio Queue backend.

## Recommendation

Prototype Audio Queue first because it has a smaller implementation surface and may provide enough latency improvement. Prototype AUHAL second if Audio Queue startup is still dominated by CoreAudio hardware wakeup, or if Audio Queue cannot be prepared without keeping the mic indicator on.

## References

- Apple: Technical Note TN2091, Device input using the HAL Output Audio Unit, https://developer.apple.com/library/archive/technotes/tn2091/_index.html
- Apple: Core Audio Common Tasks, AUHAL Unit, https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/ARoadmaptoCommonTasks/ARoadmaptoCommonTasks.html
- Apple: Core Audio overview, https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatisCoreAudio/WhatisCoreAudio.html
- Apple: Audio Unit concepts in Core Audio Essentials, https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/CoreAudioEssentials/CoreAudioEssentials.html
