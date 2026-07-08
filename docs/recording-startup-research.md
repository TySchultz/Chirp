# Recording Startup Latency Research

Last updated: 2026-07-02

This document consolidates Codex thread research from 2026-06-22 through
2026-07-02 about Chirp's hotkey-to-recording startup time. It focuses on what
we tried, what the logs showed, what worked, what did not work, and where the
recording stack currently stands.

## Executive Summary

The startup problem moved through three distinct architectures:

1. `AVAudioRecorder` writing a temporary WAV file.
2. `AVAudioEngine` tap capture with in-memory PCM, inspired by FluidVoice.
3. `Audio Queue` input capture, which is now the only intended path in the
   current working tree.

The strongest measured finding is that Chirp's Swift/controller work was not
the main delay. Once fine-grained startup logging existed, the delay repeatedly
landed in Core Audio input startup, especially when using the Studio Display
Microphone.

Current conclusion:

- `AVAudioEngine` cold startup was usually around 0.65 to 0.78 seconds.
- Prepared/paused `AVAudioEngine` reuse helped warm starts, but still left
  about 0.45 seconds in `engine.start()`.
- Keeping a running engine hot would be fastest, but macOS correctly keeps the
  microphone privacy indicator on while the input engine is running. That tradeoff
  was rejected.
- `Audio Queue` did not eliminate cold Studio Display startup, but it improved
  normal warm starts to roughly 0.27 to 0.32 seconds in the observed runs.
- AUHAL was tested and was worse than Audio Queue on the Studio Display path.
- The code has been simplified toward Audio Queue only, removing the backend
  selection experiment and the alternate AUHAL/AVAudioEngine capture paths.

## Current State

As of this pass, the active recorder implementation has been simplified to
Audio Queue only.

Current recorder shape:

- `AudioRecorder.startRecording(...)` always selects Audio Queue and logs
  `audio_capture_backend_selected_audio_queue`.
- `AudioQueueInputRecorder` uses `AudioQueueNewInput`, allocates four 20 ms
  buffers, starts with `AudioQueueStart`, and disposes on stop.
- The capture callback copies bytes into `Data` and hands them to the existing
  `AudioCapturePipeline`, which converts/resamples, computes levels, buffers
  samples, and flushes before transcription.
- Explicit non-default input devices bind via `kAudioQueueProperty_CurrentDevice`.
- If the selected input is already the system default, Chirp skips explicit
  binding to avoid unnecessary route churn.
- Audio Queue route recovery remains. After route recovery restarts Audio Queue,
  it re-registers the default-input listener.
- The old `audioCaptureBackend` defaults key, AVAudioEngine capture path, AUHAL
  capture path, and engine configuration observer are removed from the active
  source.

Existing related docs:

- `docs/audio-queue-recording-plan.md` is the original Audio Queue spike plan.
- `docs/auhal-recording-plan.md` is the original AUHAL spike plan.

Those plan docs are now partially historical. This document records the outcomes.

## Measurement Baseline

### First external benchmark

The first investigation used a synthetic `CGEvent` hotkey trigger and watched
for creation of Chirp's temporary `.wav` recording file.

Observed values:

| Scenario | Hotkey to `.wav` creation |
| --- | ---: |
| Already-running app, clean trial | 235 ms |
| Fresh-launch isolated trials | 264.8, 85.8, 51.7, 79.7, 82.7 ms |
| Fresh-launch median | 82.7 ms |
| Fresh-launch mean | 112.9 ms |

This was useful, but later proved incomplete. File creation was not the same as
"startup UX is done" or "the start sound returned." It also measured the older
`AVAudioRecorder` path.

### First in-app startup tracing

After `RecordingStartupTrace` was added, one early sample showed:

```text
av_audio_recorder_init_finished elapsed_ms=18.63
av_audio_recorder_record_begin elapsed_ms=18.65
av_audio_recorder_record_returned elapsed_ms=477.01
recording_panel_shown elapsed_ms=481.67
start_sound_play_returned elapsed_ms=519.37
```

That made the first important point clear: panel construction was not the
bottleneck. Recording startup itself was.

## Timeline

### 1. Removed obvious hot-path work

The first optimization removed two pre-recording costs from the default path:

- No longer refresh the full CoreAudio device list on every hotkey start.
- In automatic input mode, use the current macOS default input instead of
  switching the system default input and sleeping for 150 ms.

Explicit non-default device selection still needed an input switch in the old
`AVAudioRecorder` implementation, because that path could only target a
non-default input by changing the system default.

Result: good low-risk cleanup, but not enough to solve the perceived one-second
startup.

### 2. Added recording startup instrumentation

`RecordingStartupTrace` was added across the hotkey/controller/recorder path.
This separated:

- hotkey accepted
- controller start entered
- input device resolved
- input boost
- recorder initialization/start
- panel shown
- sound playback
- first capture watchdog

Result: this was one of the most valuable changes. It let later experiments
compare exact phases instead of relying on "feels slower" or "feels faster."

### 3. FluidVoice-inspired recorder rewrite

After comparing Chirp to `altic-dev/FluidVoice`, Chirp moved from
`AVAudioRecorder` file capture to an `AVAudioEngine` tap and in-memory PCM.

Copied or adapted ideas:

- Record into a thread-safe in-memory float PCM buffer.
- Avoid temp WAV write/read round trips.
- Use direct input-device binding instead of changing the system default input.
- Compute waveform levels from captured samples.
- Pad very short audio before FluidAudio transcription.
- Preload FluidAudio while recording.
- Add route-change/device recovery and stop-time instrumentation.

What worked:

- The architecture better matched Chirp's final transcription contract:
  `RecordedAudio` already wants `[Float]`.
- Stop/drain/transcription became more measurable.
- Short-audio padding and model preload improved reliability/stop behavior.

What did not fully work:

- Startup got more complex.
- `AVAudioEngine` route/configuration changes could desynchronize UI and actual
  capture.
- The app could show the pill while the underlying input was not producing
  buffers until additional watchdog/failure plumbing was added.

### 4. Fixed route recovery and UI/capture desync

After the FluidVoice-style move, there were sessions where the macOS mic
indicator looked like it was starting/stopping repeatedly while the pill stayed
active and waveforms did not move.

Likely causes:

- Route recovery could restart the engine repeatedly.
- Engine configuration changes caused by the app's own restart could trigger
  another recovery.
- If the recorder stopped itself internally, the session controller was not
  always told.

Fixes:

- Bounded/suppressed self-triggered route recovery loops.
- Propagated recorder failure back to `RecordingSessionController`.
- Added first-buffer watchdog behavior so the UI could unwind if capture did
  not actually begin.

Result: improved correctness and stopped the "pill lies while capture is dead"
class of bugs.

### 5. Reordered tap/start and first-buffer handling

The startup audit found two issues:

- The tap needed to be installed before `AVAudioEngine.start()`.
- Waiting for the first input buffer before publishing recording state made
  startup feel worse.

Changes tried:

- Install tap before engine start.
- Reduce tap buffer to 1024 frames.
- Confirm first buffer with a watchdog.
- Later, publish "engine started" as enough to proceed while keeping first
  buffer arrival as a background watchdog.

Result: better correctness and perceived responsiveness, but it did not remove
the underlying `AVAudioEngine.start()` cost.

### 6. Isolated the AVAudioEngine startup cost

Representative logs showed:

```text
av_audio_engine_start_begin elapsed_ms=22.743583
av_audio_engine_start_returned elapsed_ms=713.394375
recording_state_published elapsed_ms=714.387500
recording_panel_shown elapsed_ms=722.796833
start_sound_play_returned elapsed_ms=1172.090458
```

Interpretation:

- App/controller setup before Core Audio was about 20 ms.
- `AVAudioEngine` startup took about 690 ms in that sample.
- `throwing -10877` mapped to `kAudioUnitErr_InvalidElement`; because the engine
  still started and first capture arrived, it appeared to be internal Core Audio
  setup noise rather than a fatal app error.
- `NSSound.play()` sometimes added a surprisingly large delay to the returned
  call, though it occurred after recording startup in the flow.

Later logs repeated the same shape:

- `AVAudioEngine` cold path: roughly 664 to 785 ms.
- Input volume boost: usually about 9 to 22 ms, not the main issue.
- Default-device bind skip helped remove explicit binding churn but did not
  erase the cold engine/device wake cost.

### 7. Showed preparing UI immediately

Since the app was waiting to show the recording panel until after the engine
started, a preparing state was added:

- publish `isPreparingRecording`
- show the pill immediately
- switch to true recording/waveform after audio startup succeeds
- eventually remove the mic glyph from the preparing pill, leaving only the pill
  itself

Result: much better hotkey feedback, but intentionally not counted as reducing
actual mic startup time.

### 8. Tried keeping AVAudioEngine hot

Several variants were explored:

1. Keep the engine running with capture disabled.
2. Keep it running only for a 5-second grace period.
3. Keep the object/pipeline prepared but paused between recordings.

Findings:

- Keeping the engine running would likely make the next hotkey near-instant.
- macOS shows the microphone privacy indicator while the input engine is running,
  even if Chirp discards idle buffers.
- That all-day privacy indicator was unacceptable for a short-recording app.
- A 5-second keep-alive was implemented, then removed because the focus shifted
  to options that do not keep the mic active.

Prepared/paused engine reuse results:

| Run | Key result |
| --- | --- |
| Cold AVAudioEngine | Engine section about 758 ms |
| Warm prepared reuse | Setup before start about 2-3 ms |
| Warm prepared reuse | `engine.start()` still about 445-452 ms |
| Ready time after reuse | about 470-477 ms |

Result: prepared reuse saved about 300 ms by avoiding input-node/tap/prepare
work, but still left roughly 0.45 seconds in hardware/device startup. Useful,
but not good enough, and still close to the privacy-indicator boundary.

### 9. Compared OpenWhispr, FluidAudio, and Handy

OpenWhispr:

- Electron/MediaRecorder, not directly portable.
- Useful idea: warm the mic before the user cares.
- Not acceptable if it leaves the mic indicator active all day.

FluidAudio:

- Mostly SDK/CLI and inference/session logic, not a full hotkey dictation app.
- Confirmed the tap-before-start shape and small buffers like 1024/1600 frames.
- More relevant to streaming transcription than hotkey-to-mic-open latency.

Handy:

- Tauri/Rust with `cpal`.
- Uses an open/play input stream and gates whether samples are retained.
- Has always-on and on-demand modes; on-demand can lazily close after 30 seconds.
- Good callback architecture: do little in the audio callback, process off-thread.
- Not copied wholesale because keeping the stream open violates the mic-indicator
  requirement.

Concrete copied idea from Handy comparison:

- If the selected input is already the system default, skip explicit device
  binding. This removed `audio-input-bound` from the hot path in that case and
  reduced route/config churn.

### 10. Planned lower-level alternatives

Two plan docs were created:

- `docs/audio-queue-recording-plan.md`
- `docs/auhal-recording-plan.md`

The decision at the time: try Audio Queue first because it is lower-level than
`AVAudioEngine` but much simpler and safer than AUHAL. Keep AUHAL as plan B.

### 11. Implemented Audio Queue backend

Audio Queue was initially added as a default experimental backend with an
AVAudioEngine fallback behind `audioCaptureBackend=avAudioEngine`.

Implementation shape:

- `AudioQueueNewInput`
- native-rate Float32 PCM
- four 20 ms buffers
- callback copies to `Data`
- existing `AudioCapturePipeline` handles conversion, levels, buffering, and
  transcription handoff
- queue stopped and disposed after recording so the mic indicator can turn off

First useful Audio Queue timings:

| Recording | Ready | Queue Create | `AudioQueueStart` |
| --- | ---: | ---: | ---: |
| Cold | 780 ms | 216 ms | 499 ms |
| Warm 1 | 284 ms | 208 ms | 53 ms |
| Warm 2 | 271 ms | 204 ms | 39 ms |

Another non-idle baseline:

| Recording | Panel Ready | Queue Create | Queue Start |
| --- | ---: | ---: | ---: |
| Cold | 767 ms | 198 ms | 500 ms |
| Warm 1 | 288 ms | 225 ms | 36 ms |
| Warm 2 | 316 ms | 4 ms | 279 ms |
| Warm 3 | 319 ms | 252 ms | 41 ms |

Result:

- Cold startup on the Studio Display Microphone was still driver-bound and
  roughly as expensive as AVAudioEngine.
- Warm starts improved meaningfully, usually around 270 to 320 ms ready time.
- The consistent remaining warm cost was often `AudioQueueNewInput`, around
  200 ms.
- Occasional warm outliers came from `AudioQueueStart` blocking for hundreds of
  milliseconds again, likely Studio Display/CoreAudio driver behavior.

### 12. Tried idle-prepared Audio Queue

Hypothesis: pre-create the Audio Queue while idle, but do not call
`AudioQueueStart`, so the hotkey path only starts the already-prepared queue.

Implementation:

- Added a `prepareAudioQueueWhileIdle` defaults flag.
- Refactored `AudioQueueInputRecorder` to have a prepared-but-not-recording
  state.
- Scheduled idle preparation after app startup and after processing.

Observed result:

- The test logs did not actually hit the reuse path. They still showed
  `audio_queue_prepare_begin` and `audio_queue_created` during the hotkey path,
  without `audio_queue_reuse_prepared`.
- The flag was not set in one run.
- In another run, scheduling/defaults behavior made the test inconclusive.

Decision:

- Revert the idle-prep/defaults experiment.
- Keep the plain Audio Queue path: create, start, stop, dispose per recording.

### 13. Tested AUHAL

AUHAL was implemented as an opt-in backend after Audio Queue.

There were two rounds of false starts:

- Preferences were set to `auhal`, but an older running binary did not know that
  enum case and silently fell back to Audio Queue.
- Added explicit backend-selected markers so logs could not fool us:
  `audio_capture_backend_selected_audio_queue` and
  `audio_capture_backend_selected_auhal`.

Once AUHAL actually ran, the timing was worse on Studio Display:

| AUHAL phase | Observed cost |
| --- | ---: |
| `auhal_device_selected` | about 190-230 ms |
| `AudioOutputUnitStart` | about 435-455 ms |

Result:

- AUHAL added a slow device-selection phase before paying a hardware start cost
  similar to the remaining Audio Queue/AVAudioEngine cost.
- It was worse than Audio Queue for this device and workload.
- AUHAL was removed during the final simplification.

### 14. Simplified to Audio Queue only

Final direction:

- Remove backend selection.
- Remove `audioCaptureBackend` defaults support.
- Remove AUHAL implementation.
- Remove AVAudioEngine capture/start/reuse path.
- Keep Audio Queue instrumentation, route recovery, first-capture watchdog, and
  the shared capture pipeline.

This is reflected in the current `Chirp/AudioRecorder.swift` implementation.

## What Worked

| Approach | Outcome |
| --- | --- |
| Startup tracing | Very successful. It made every later experiment comparable. |
| Removing hot-path device refresh/default switching | Good cleanup. Removed avoidable pre-recording work. |
| In-memory PCM pipeline | Good architecture for stop/drain/transcription. Avoided WAV round trip. |
| Route recovery/failure callback plumbing | Fixed cases where UI said recording but capture was dead. |
| Tap-before-start and first-capture watchdog | Improved correctness of AVAudioEngine path. |
| Preparing UI immediately | Improved perceived responsiveness without lying about capture readiness. |
| Default-device bind skip | Reduced unnecessary route churn when selected mic was already the default. |
| Audio Queue backend | Best measured backend for normal repeated recordings with mic indicator off between recordings. |
| Removing alternate backends after testing | Reduced complexity and removed confusing experimental paths. |

## What Did Not Work

| Approach | Why it failed or was rejected |
| --- | --- |
| Using external `.wav` creation as the only benchmark | It under-measured perceived startup and did not capture sound/UI/capture-readiness timing. |
| `AVAudioRecorder` path | Simple but had startup delay and file write/read overhead. |
| FluidVoice-style AVAudioEngine as a final answer | Better architecture, but `AVAudioEngine.start()` remained slow and added lifecycle complexity. |
| Waiting for first buffer before publishing recording | Correct but made the UI feel delayed; moved to watchdog instead. |
| Keeping engine running all day | Fast, but macOS mic indicator stays on. Rejected. |
| 5-second AVAudioEngine keep-alive | Partial compromise, then removed to avoid mic-indicator/privacy tradeoff. |
| Prepared/paused AVAudioEngine | Saved graph setup, but warm starts still spent about 445-452 ms in hardware start. |
| Idle-prepared Audio Queue | Inconclusive and not reliably exercised; reverted. |
| AUHAL | More complex and slower than Audio Queue on Studio Display. |
| AudioKit | Not useful for this problem because it mostly wraps the AVAudioEngine world. |

## Device-Specific Finding

Most of the stubborn delay appears tied to Core Audio and the Studio Display
Microphone path:

- `AVAudioEngine.start()` repeatedly blocked around 0.65 to 0.78 seconds cold.
- Prepared `AVAudioEngine` still blocked around 0.45 seconds on start.
- Audio Queue cold starts still blocked around 0.50 seconds in `AudioQueueStart`.
- AUHAL still blocked around 0.44 seconds in `AudioOutputUnitStart`, plus extra
  device-selection time.
- Logs sometimes included AppleUSBAudioEngine/reconfiguration noise during slow
  starts.

The built-in Mac mic vs Studio Display mic comparison was recommended several
times, but the reviewed thread record does not show a completed side-by-side
table. That remains the highest-value measurement gap.

## Remaining Questions

1. How much faster is the built-in Mac microphone than the Studio Display
   Microphone on the current Audio Queue-only implementation?
2. Can `AudioQueueNewInput` be safely prepared while idle without showing the
   mic indicator if scheduled more aggressively and verified carefully?
3. Can the Audio Queue callback avoid the current `Data` copy without affecting
   startup timing or reliability?
4. Is start sound playback still adding noticeable latency or main-actor
   contention after the Audio Queue simplification?
5. Are there remaining route recovery edge cases after removing AVAudioEngine
   configuration notifications?

## Recommended Next Measurements

Use the current Audio Queue-only path and collect cold plus three warm starts for:

| Device | Needed |
| --- | --- |
| Studio Display Microphone | Yes, current baseline |
| Built-in Mac microphone | Yes, compare hardware wake cost |
| Any Bluetooth mic/headset | Optional, likely slower and useful for guardrails |

For each run, capture:

- `start_request_accepted`
- `recording_panel_shown` or `recording_panel_ready`
- `audio_queue_prepare_begin`
- `audio_queue_created`
- `audio_queue_buffers_enqueued`
- `audio_queue_start_call_begin`
- `audio_queue_start_call_returned`
- `audio_queue_first_buffer_received`
- first waveform movement if available
- stop-to-`audio-queue-stopped-disposed`
- whether the macOS mic indicator disappears immediately after stop

Primary metric:

```text
hotkey -> audio_queue_first_buffer_received
```

Secondary metrics:

```text
hotkey -> panel ready
audio_queue_prepare_begin -> audio_queue_created
audio_queue_start_call_begin -> audio_queue_start_call_returned
stop -> mic indicator gone
```

## Source Threads

| Date | Thread | ID | Main contribution |
| --- | --- | --- | --- |
| 2026-06-22 | Reduce recording start delay | `019eef94-bf00-7943-a9cd-c94226b0090f` | Removed hot-path device refresh and auto default-device switching. |
| 2026-06-25 | Benchmark recording start latency | `019effbf-8320-7702-b24c-f813bffd1059` | External baseline, then `RecordingStartupTrace` instrumentation. |
| 2026-06-27 | Analyze FluidVoice audio stack | `019f094a-81bd-7333-914b-784852c86999` | FluidVoice comparison and AVAudioEngine/in-memory PCM rewrite. |
| 2026-06-29 | Fix recording start cycle | `019f14be-1631-7d70-ab14-c6c89d084f8a` | Route recovery loop and stale UI/capture-state fixes. |
| 2026-07-01 | Audit recording startup | `019f1f73-7db0-7100-91e6-7e8352e37ede` | Tap-before-start, first-buffer watchdog, press-and-hold race fixes. |
| 2026-07-02 | Reduce recording start delay | `019f2273-d73a-79e1-9d4d-fb4dff6f07a5` | OpenWhispr/FluidAudio comparisons, launch mic warmup, tap `outputFormat` adjustment. |
| 2026-07-02 | Clarify startup timing | `019f2284-40c4-7751-bde9-dabe319154ed` | Confirmed 0.7 s was real and mostly inside engine startup. |
| 2026-07-02 | Review recording hotkey flow | `019f2283-cd20-7fc3-981a-647ad2d7c3e3` | Main experiment thread: Handy comparison, preparing UI/default-bind skip, keep-alive, prepared engine, Audio Queue, idle queue, AUHAL, final Audio Queue-only simplification. |
| 2026-07-02 | Explore AudioEngine alternatives | `019f239b-ff5b-7392-9e33-a38523a39544` | Lower-level API research, prepared engine results, Audio Queue/AUHAL plans. |

## Related Commits

| Commit | Message | Relevance |
| --- | --- | --- |
| `8d1d481` | Instrument recording startup latency | Added timing trace points. |
| `d0834d0` | Improve audio recording reliability | FluidVoice-style recorder and reliability work. |
| `c08bc3a` | Stabilize audio route recovery | Fixed route recovery loop/UI desync issues. |
| `e1735ae` | Improve recording startup responsiveness | Baseline before lower-level backend spike, including planning docs. |
| `dcc6b21` | Speed up recording startup with Audio Queue | Audio Queue backend work. |

## Bottom Line

The current best-supported direction is Audio Queue only, with no always-on mic
engine. It preserves the privacy requirement, removes the AVAudioEngine/AUHAL
complexity, and gives the best observed repeated-recording startup times.

The remaining ceiling is probably hardware/device wakeup, especially on the
Studio Display Microphone. The next serious improvement should start with a
device comparison and only then revisit idle preparation or lower-copy callback
work.
