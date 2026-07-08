//
//  RecordingSessionController.swift
//  Chirp
//
//  Created by Codex on 6/8/26.
//

import ApplicationServices
import Cocoa
import Combine
import Foundation
import KeyboardShortcuts
import OSLog
import QuartzCore
import SwiftUI

struct RecordingStartupTrace: @unchecked Sendable {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "com.chirpapp.Chirp"
  private static let log = OSLog(subsystem: subsystem, category: "RecordingStartup")
  private static let logger = Logger(subsystem: subsystem, category: "RecordingStartup")

  private let signpostID: OSSignpostID
  private let hotkeyReceivedAt: CFTimeInterval

  init(hotkeyReceivedAt: CFTimeInterval = CACurrentMediaTime()) {
    self.hotkeyReceivedAt = hotkeyReceivedAt
    self.signpostID = OSSignpostID(log: Self.log)

    os_signpost(.begin, log: Self.log, name: "HotkeyToRecording", signpostID: signpostID)
    event("start_request_accepted")
  }

  func event(_ name: StaticString) {
    let elapsedMilliseconds = (CACurrentMediaTime() - hotkeyReceivedAt) * 1000
    let eventName = String(describing: name)

    os_signpost(
      .event,
      log: Self.log,
      name: name,
      signpostID: signpostID,
      "%{public}.2f ms",
      elapsedMilliseconds
    )
    Self.logger.info("recording-startup event=\(eventName, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public)")
  }

  func end(_ name: StaticString) {
    event(name)
    os_signpost(.end, log: Self.log, name: "HotkeyToRecording", signpostID: signpostID)
  }
}

final class RecordingShortcutPressState: @unchecked Sendable {
  private let lock = NSLock()
  private var activeToken: UUID?

  func pressBegan() -> UUID {
    lock.lock()
    defer { lock.unlock() }

    if let activeToken {
      return activeToken
    }

    let token = UUID()
    activeToken = token
    return token
  }

  func pressEnded() {
    lock.lock()
    activeToken = nil
    lock.unlock()
  }

  func isPressActive(_ token: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    return activeToken == token
  }
}

@MainActor
final class RecordingSessionController: ObservableObject {
  private static let processingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.chirpapp.Chirp",
    category: "RecordingProcessing"
  )
  private static let recordingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.chirpapp.Chirp",
    category: "RecordingSession"
  )

  private let recordingPanelSize = NSSize(width: 178, height: 44)
  private let iconPanelSize = NSSize(width: 52, height: 44)

  @Published var isRecording = false
  @Published var isPreparingRecording = false
  @Published var isProcessing = false
  @Published var recordingAudioLevels: [Float] = []
  @Published var latestChirp = "Your latest chirp will show here"
  @Published var recentTranscriptions: [TranscriptionOutput] = []
  @Published private(set) var inputDevices: [AudioInputDevice] = []

  let inputDeviceMonitor = AudioInputDeviceMonitor()

  private let audioRecorder = AudioRecorder()
  private let transcriptionManager: FluidAudioTranscriptionManager
  private let recordingStartedSound = NSSound(named: NSSound.Name("Pop"))
  private var recordingPanel: FloatingPanel?
  private var didSetupKeyboardShortcut = false
  private var isStartingRecording = false
  nonisolated private let shortcutPressState = RecordingShortcutPressState()
  private var cancellables: Set<AnyCancellable> = []

  init(transcriptionManager: FluidAudioTranscriptionManager) {
    self.transcriptionManager = transcriptionManager
    inputDevices = inputDeviceMonitor.devices
    inputDeviceMonitor.$devices
      .receive(on: DispatchQueue.main)
      .sink { [weak self] devices in
        self?.inputDevices = devices
      }
      .store(in: &cancellables)
    setupKeyboardShortcut()
    ensureFloatingPanel()
  }

  func refreshInputDevices() {
    inputDeviceMonitor.refresh()
    resetUnavailableInputSelectionIfNeeded()
  }

  func resetUnavailableInputSelectionIfNeeded() {
    let selectionID = recordingInputDeviceUID
    guard selectionID != AudioInputDevice.automaticSelectionID,
          !inputDevices.contains(where: { $0.uid == selectionID }) else {
      return
    }

    recordingInputDeviceUID = AudioInputDevice.automaticSelectionID
  }

  func hideRecordingPanel() {
    recordingPanel?.orderOut(nil)
  }

  private func showRecordingPanel() {
    ensureFloatingPanel()
    guard let panel = recordingPanel else {
      return
    }

    // Show the recording panel at full width immediately. Resizing from the icon
    // width during recording start reads as a left-anchored entrance.
    panel.setFrame(panelFrame(forContentSize: recordingPanelSize), display: true)
    panel.orderFrontRegardless()
  }

  private func showPreparingPanel() {
    ensureFloatingPanel()
    guard let panel = recordingPanel else {
      return
    }

    panel.setFrame(panelFrame(forContentSize: iconPanelSize), display: true)
    panel.orderFrontRegardless()
  }

  private func showProcessingPanel() {
    ensureFloatingPanel()
    resizeRecordingPanel(to: iconPanelSize, animated: true)
    recordingPanel?.orderFrontRegardless()
  }

  private func showResultPanel() {
    ensureFloatingPanel()
    resizeRecordingPanel(to: iconPanelSize, animated: true)
    recordingPanel?.orderFrontRegardless()
  }

  private func ensureFloatingPanel() {
    guard recordingPanel == nil else {
      return
    }

    let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: recordingPanelSize), backing: .buffered, defer: false)
    panel.title = "Recording Status"
    panel.contentView = NSHostingView(
      rootView: RecordingPillView(
        recordingSession: self,
        dismissPanel: { [weak self] in
          self?.hideRecordingPanel()
        }
      )
      .edgesIgnoringSafeArea(.top)
    )
    recordingPanel = panel
    positionRecordingPanel()
  }

  private func resizeRecordingPanel(to size: NSSize, animated: Bool) {
    guard let panel = recordingPanel else {
      return
    }

    let frame = panelFrame(forContentSize: size)

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        panel.animator().setFrame(frame, display: true)
      }
    } else {
      panel.setFrame(frame, display: true)
    }
  }

  private func positionRecordingPanel() {
    guard let panel = recordingPanel else {
      return
    }

    panel.setFrame(panelFrame(forContentSize: panel.contentView?.bounds.size ?? recordingPanelSize), display: true)
  }

  private func panelFrame(forContentSize size: NSSize) -> NSRect {
    let visibleFrame = desktopVisibleFrame
    let contentRect = NSRect(
      x: visibleFrame.midX - size.width / 2,
      y: visibleFrame.minY + 42,
      width: size.width,
      height: size.height
    )
    return recordingPanel?.frameRect(forContentRect: contentRect) ?? contentRect
  }

  private var desktopVisibleFrame: NSRect {
    let visibleFrames = NSScreen.screens.map(\.visibleFrame)
    guard let firstFrame = visibleFrames.first else {
      return NSScreen.main?.visibleFrame ?? .zero
    }

    return visibleFrames.dropFirst().reduce(firstFrame) { partialResult, frame in
      partialResult.union(frame)
    }
  }

  private func setupKeyboardShortcut() {
    guard !didSetupKeyboardShortcut else {
      return
    }

    didSetupKeyboardShortcut = true

    KeyboardShortcuts.onKeyDown(for: .startRecording) { [weak self] in
      let hotkeyReceivedAt = CACurrentMediaTime()
      let shortcutMode = Self.currentShortcutMode()
      let pressToken = shortcutMode == .pressAndHold ? self?.shortcutPressState.pressBegan() : nil

      Task { @MainActor in
        guard let self else {
          return
        }

        switch shortcutMode {
          case .toggle:
            if self.isRecording {
              self.stopRecordingAndProcess()
            } else {
              await self.startRecording(startupTrace: RecordingStartupTrace(hotkeyReceivedAt: hotkeyReceivedAt))
            }
          case .pressAndHold:
            if !self.isRecording {
              await self.startRecording(
                pressAndHoldToken: pressToken,
                startupTrace: RecordingStartupTrace(hotkeyReceivedAt: hotkeyReceivedAt)
              )
            }
        }
      }
    }

    KeyboardShortcuts.onKeyUp(for: .startRecording) { [weak self] in
      self?.shortcutPressState.pressEnded()

      Task { @MainActor in
        guard let self,
              Self.currentShortcutMode() == .pressAndHold else {
          return
        }

        if self.isRecording {
          self.stopRecordingAndProcess()
        }
      }
    }
  }

  private static func currentShortcutMode() -> RecordingShortcutMode {
    let rawValue = UserDefaults.standard.string(forKey: "recordingShortcutMode")
    return rawValue.flatMap(RecordingShortcutMode.init(rawValue:)) ?? .toggle
  }

  private func startRecording(
    pressAndHoldToken: UUID? = nil,
    startupTrace: RecordingStartupTrace? = nil
  ) async {
    startupTrace?.event("start_recording_entered")

    guard !isStartingRecording, !isPreparingRecording, !isRecording, !isProcessing else {
      startupTrace?.end("start_request_rejected")
      return
    }

    if let pressAndHoldToken,
       !shortcutPressState.isPressActive(pressAndHoldToken) {
      startupTrace?.end("press_and_hold_released_before_start")
      return
    }

    isStartingRecording = true
    defer {
      isStartingRecording = false
    }

    latestChirp = ""
    isPreparingRecording = true
    startupTrace?.event("recording_preparing_state_published")
    showPreparingPanel()
    startupTrace?.event("recording_panel_shown")

    recordingAudioLevels = Array(repeating: 0, count: WaveformView.barCount)
    startupTrace?.event("recording_audio_levels_reset")

    let selectionID = recordingInputDeviceUID
    let selectedDevice = recordingInputDevice(for: selectionID)
    startupTrace?.event("recording_input_device_resolved")
    let audioLevelHandler: AudioRecorder.AudioLevelHandler = { [weak self] level in
      guard let self else {
        return
      }

      self.recordingAudioLevels.append(level)
      if self.recordingAudioLevels.count > WaveformView.barCount {
        self.recordingAudioLevels.removeFirst(self.recordingAudioLevels.count - WaveformView.barCount)
      }
    }

    guard await audioRecorder.startRecording(
      inputDevice: selectedDevice,
      onAudioLevel: audioLevelHandler,
      onRecordingFailure: { [weak self] error in
        Task { @MainActor in
          self?.recordingDidFail(error)
        }
      },
      boostInputVolume: boostMicrophoneInput && (selectedDevice?.supportsInputVolumeBoost ?? true),
      startupTrace: startupTrace
    ) else {
      isPreparingRecording = false
      recordingAudioLevels = []
      startupTrace?.end("audio_recorder_start_failed")
      return
    }

    if let pressAndHoldToken,
       !shortcutPressState.isPressActive(pressAndHoldToken) {
      isPreparingRecording = false
      audioRecorder.cancelRecording()
      recordingAudioLevels = []
      startupTrace?.end("press_and_hold_released_before_ready")
      return
    }

    transcriptionManager.loadModel()
    startupTrace?.event("transcription_model_preload_requested")

    isPreparingRecording = false
    isRecording = true
    startupTrace?.event("recording_state_published")
    showRecordingPanel()
    startupTrace?.event("recording_panel_ready")
    startupTrace?.event("start_sound_begin")
    playSound(recordingStartedSound)
    startupTrace?.end("start_sound_play_returned")
  }

  private func recordingDidFail(_ error: Error) {
    guard isRecording || isPreparingRecording else {
      return
    }

    Self.recordingLogger.error("recording-capture-failed error=\(error.localizedDescription, privacy: .public)")
    recordingAudioLevels = []
    withAnimation {
      isPreparingRecording = false
      isRecording = false
      isProcessing = false
    }
    hideRecordingPanel()
  }

  private func recordingInputDevice(for selectionID: String) -> AudioInputDevice? {
    guard selectionID != AudioInputDevice.automaticSelectionID else {
      return nil
    }

    if let selectedDevice = inputDevices.first(where: { $0.uid == selectionID }) {
      return selectedDevice
    }

    inputDeviceMonitor.refresh()
    inputDevices = inputDeviceMonitor.devices

    guard let selectedDevice = inputDevices.first(where: { $0.uid == selectionID }) else {
      recordingInputDeviceUID = AudioInputDevice.automaticSelectionID
      return nil
    }

    return selectedDevice
  }

  private func stopRecordingAndProcess() {
    guard isRecording, !isProcessing else {
      return
    }

    audioRecorder.stopRecording()
    withAnimation {
      isPreparingRecording = false
      isRecording = false
    }
    processAudio()
  }

  private func processAudio() {
    guard !isProcessing else {
      return
    }

    withAnimation {
      isProcessing = true
    }
    showProcessingPanel()

    Task {
      let audioDrainStartedAt = CACurrentMediaTime()
      switch await audioRecorder.getRecordedAudio() {
        case .success(let recordedAudio):
          let audioDrainMilliseconds = (CACurrentMediaTime() - audioDrainStartedAt) * 1000
          Self.processingLogger.info("recorded-audio-ready samples=\(recordedAudio.sampleCount, privacy: .public) duration=\(recordedAudio.duration, privacy: .public) drain_ms=\(audioDrainMilliseconds, privacy: .public)")
          do {
            let transcriptionStartedAt = CACurrentMediaTime()
            let transcription = try await transcriptionManager.transcribe(recordedAudio: recordedAudio)
            let transcriptionMilliseconds = (CACurrentMediaTime() - transcriptionStartedAt) * 1000
            Self.processingLogger.info("transcription-complete chars=\(transcription.count, privacy: .public) transcription_ms=\(transcriptionMilliseconds, privacy: .public)")
            await endTranscription(transcription: transcription, output: transcription, duration: recordedAudio.duration)
          } catch {
            await MainActor.run {
              print("Transcription error: \(error.localizedDescription)")
              withAnimation {
                isProcessing = false
              }
              hideRecordingPanel()
            }
          }
        case .failure(let error):
          await MainActor.run {
            print("Error getting recorded audio: \(error.localizedDescription)")
            withAnimation {
              isProcessing = false
            }
            hideRecordingPanel()
          }
      }
    }
  }

  private func endTranscription(transcription: String, output: String, duration: TimeInterval) async {
    await MainActor.run {
      let inputCount = transcription.split(separator: " ").count
      let outputCount = output.split(separator: " ").count

      guard inputCount > 0 || transcription != "[BLANK_AUDIO]" else {
        withAnimation {
          isProcessing = false
        }
        hideRecordingPanel()
        return
      }

      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(output, forType: .string)
      if automaticallyPasteTranscript {
        simulatePaste()
      }

      if inputCount > 0 {
        incrementIntegerDefault("totalWordsTranscribedIn", by: inputCount)
        incrementIntegerDefault("totalWordsTranscribedOut", by: outputCount)
        incrementIntegerDefault("totalTranscriptions", by: 1)
        incrementDoubleDefault("totalAudioSeconds", by: duration)
      }

      let newTranscriptionOutput = TranscriptionOutput(transcription: transcription, output: output, timestamp: Date())
      withAnimation {
        recentTranscriptions.append(newTranscriptionOutput)
      }

      if recentTranscriptions.count > 10 {
        withAnimation {
          _ = recentTranscriptions.removeFirst()
        }
      }

      withAnimation {
        latestChirp = newTranscriptionOutput.output
        isProcessing = false
      }
      showResultPanel()
    }
  }

  private var automaticallyPasteTranscript: Bool {
    UserDefaults.standard.object(forKey: "automaticallyPasteTranscript") as? Bool ?? true
  }

  private var boostMicrophoneInput: Bool {
    UserDefaults.standard.object(forKey: "boostMicrophoneInput") as? Bool ?? false
  }

  private var recordingInputDeviceUID: String {
    get {
      UserDefaults.standard.string(forKey: "recordingInputDeviceUID") ?? AudioInputDevice.automaticSelectionID
    }
    set {
      UserDefaults.standard.set(newValue, forKey: "recordingInputDeviceUID")
    }
  }

  private func incrementIntegerDefault(_ key: String, by amount: Int) {
    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + amount, forKey: key)
  }

  private func incrementDoubleDefault(_ key: String, by amount: Double) {
    UserDefaults.standard.set(UserDefaults.standard.double(forKey: key) + amount, forKey: key)
  }

  private func simulatePaste() {
    let source = CGEventSource(stateID: .hidSystemState)
    let pasteDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
    let pasteUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

    pasteDownEvent?.flags = .maskCommand
    pasteUpEvent?.flags = .maskCommand

    pasteDownEvent?.post(tap: .cghidEventTap)
    pasteUpEvent?.post(tap: .cghidEventTap)
  }

  private func playSound(_ sound: NSSound?) {
    guard let sound else {
      return
    }

    sound.stop()
    sound.currentTime = 0
    sound.play()
  }

}
