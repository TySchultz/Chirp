//
//  AudioRecorder.swift
//  Squeek
//
//

import SwiftUI
import Accelerate
import AVFAudio
import AudioToolbox
import AudioUnit
import CoreAudio
import Darwin
import Foundation
import OSLog

struct RecordedAudio {
  let pcmData: Data
  let sampleRate: Double
  let duration: TimeInterval

  var sampleCount: Int {
    pcmData.count / MemoryLayout<Float>.size
  }
}

struct AudioInputDevice: Identifiable, Hashable {
  static let automaticSelectionID = "auto"

  let deviceID: AudioDeviceID
  let uid: String
  let name: String
  let transportType: UInt32
  let isDefault: Bool

  var id: String {
    uid
  }

  var isBuiltIn: Bool {
    transportType == kAudioDeviceTransportTypeBuiltIn
  }

  var isBluetooth: Bool {
    transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
  }

  var supportsInputVolumeBoost: Bool {
    !isBluetooth
  }

  var displayName: String {
    if isDefault {
      return "\(name) (System Default)"
    }

    return name
  }

  static func availableInputDevices() -> [AudioInputDevice] {
    let defaultDeviceID = currentDefaultInputDeviceID()
    return allAudioDeviceIDs()
      .filter(hasInputChannels)
      .compactMap { deviceID in
        guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
              let name = stringProperty(kAudioObjectPropertyName, for: deviceID),
              let transportType = uint32Property(kAudioDevicePropertyTransportType, for: deviceID) else {
          return nil
        }

        return AudioInputDevice(
          deviceID: deviceID,
          uid: uid,
          name: name,
          transportType: transportType,
          isDefault: deviceID == defaultDeviceID
        )
      }
      .sorted { lhs, rhs in
        if lhs.isBuiltIn != rhs.isBuiltIn {
          return lhs.isBuiltIn
        }

        if lhs.isBluetooth != rhs.isBluetooth {
          return !lhs.isBluetooth
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
  }

  static func resolvedDevice(for selectionID: String, in devices: [AudioInputDevice]) -> AudioInputDevice? {
    if selectionID != automaticSelectionID,
       let selectedDevice = devices.first(where: { $0.uid == selectionID }) {
      return selectedDevice
    }

    return bestAutomaticDevice(in: devices)
  }

  static func bestAutomaticDevice(in devices: [AudioInputDevice]) -> AudioInputDevice? {
    devices.first(where: \.isBuiltIn)
      ?? devices.first(where: { !$0.isBluetooth })
      ?? devices.first(where: \.isDefault)
      ?? devices.first
  }

  static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
    let transportType = uint32Property(kAudioDevicePropertyTransportType, for: deviceID)
    return transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
  }

  static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var propertySize = UInt32(MemoryLayout<Float64>.size)
    var sampleRate: Float64 = 0

    let status = AudioObjectGetPropertyData(
      deviceID,
      &propertyAddress,
      0,
      nil,
      &propertySize,
      &sampleRate
    )

    guard status == noErr, sampleRate > 0 else {
      return nil
    }

    return sampleRate
  }

  static func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32? {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var propertySize: UInt32 = 0

    guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize) == noErr,
          propertySize > 0 else {
      return nil
    }

    let bufferListPointer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(propertySize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListPointer.deallocate() }

    let audioBufferList = bufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard AudioObjectGetPropertyData(
      deviceID,
      &propertyAddress,
      0,
      nil,
      &propertySize,
      audioBufferList
    ) == noErr else {
      return nil
    }

    let channelCount = UnsafeMutableAudioBufferListPointer(audioBufferList)
      .reduce(UInt32(0)) { partialResult, buffer in
        partialResult + buffer.mNumberChannels
      }

    return channelCount > 0 ? channelCount : nil
  }

  static func currentDefaultInputDeviceID() -> AudioDeviceID? {
    var deviceID = AudioDeviceID()
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      &propertySize,
      &deviceID
    )

    guard status == noErr, deviceID != kAudioObjectUnknown else {
      return nil
    }

    return deviceID
  }

  static func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
    var mutableDeviceID = deviceID
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    return AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      UInt32(MemoryLayout<AudioDeviceID>.size),
      &mutableDeviceID
    ) == noErr
  }

  private static func allAudioDeviceIDs() -> [AudioDeviceID] {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var propertySize: UInt32 = 0

    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      &propertySize
    ) == noErr else {
      return []
    }

    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = Array(repeating: AudioDeviceID(), count: deviceCount)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      &propertySize,
      &deviceIDs
    )

    return status == noErr ? deviceIDs : []
  }

  private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
    (inputChannelCount(for: deviceID) ?? 0) > 0
  }

  private static func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var propertySize = UInt32(MemoryLayout<CFString>.size)
    let valuePointer = UnsafeMutableRawPointer.allocate(
      byteCount: MemoryLayout<CFString>.size,
      alignment: MemoryLayout<CFString>.alignment
    )
    defer {
      valuePointer.deallocate()
    }

    let status = AudioObjectGetPropertyData(
      deviceID,
      &propertyAddress,
      0,
      nil,
      &propertySize,
      valuePointer
    )

    guard status == noErr else {
      return nil
    }

    return valuePointer.load(as: CFString.self) as String
  }

  private static func uint32Property(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> UInt32? {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var propertySize = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0

    let status = AudioObjectGetPropertyData(
      deviceID,
      &propertyAddress,
      0,
      nil,
      &propertySize,
      &value
    )

    return status == noErr ? value : nil
  }
}

final class AudioInputDeviceMonitor: ObservableObject {
  @Published private(set) var devices: [AudioInputDevice] = AudioInputDevice.availableInputDevices()

  private var deviceListAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  private var defaultInputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    self?.refresh()
  }

  init() {
    addListeners()
  }

  func refresh() {
    devices = AudioInputDevice.availableInputDevices()
  }

  func resolvedDevice(for selectionID: String) -> AudioInputDevice? {
    AudioInputDevice.resolvedDevice(for: selectionID, in: devices)
  }

  deinit {
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &deviceListAddress,
      DispatchQueue.main,
      listenerBlock
    )
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &defaultInputAddress,
      DispatchQueue.main,
      listenerBlock
    )
  }

  private func addListeners() {
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &deviceListAddress,
      DispatchQueue.main,
      listenerBlock
    )
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &defaultInputAddress,
      DispatchQueue.main,
      listenerBlock
    )
  }
}

final class CoreAudioInputVolumeBoost {
  static let shared = CoreAudioInputVolumeBoost()

  private let lock = NSLock()
  private var restoredDeviceID: AudioDeviceID?
  private var restoredVolume: Float?

  private init() {}

  func apply(to deviceID: AudioDeviceID? = nil, targetVolume: Float = 1.0) {
    lock.lock()
    defer { lock.unlock() }

    guard restoredDeviceID == nil,
          let deviceID = deviceID ?? AudioInputDevice.currentDefaultInputDeviceID(),
          !AudioInputDevice.isBluetoothDevice(deviceID),
          let currentVolume = Self.inputVolume(for: deviceID),
          currentVolume < targetVolume,
          Self.setInputVolume(targetVolume, for: deviceID) else {
      return
    }

    restoredDeviceID = deviceID
    restoredVolume = currentVolume
  }

  func restore() {
    lock.lock()
    defer { lock.unlock() }

    defer {
      restoredDeviceID = nil
      restoredVolume = nil
    }

    guard let restoredDeviceID,
          let restoredVolume else {
      return
    }

    _ = Self.setInputVolume(restoredVolume, for: restoredDeviceID)
  }
  private static func inputVolume(for deviceID: AudioDeviceID) -> Float? {
    guard let propertyAddress = inputVolumePropertyAddress(for: deviceID) else {
      return nil
    }

    var volume: Float32 = 0
    var propertySize = UInt32(MemoryLayout<Float32>.size)
    var mutableAddress = propertyAddress
    let status = AudioObjectGetPropertyData(
      deviceID,
      &mutableAddress,
      0,
      nil,
      &propertySize,
      &volume
    )

    return status == noErr ? volume : nil
  }

  private static func setInputVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool {
    guard let propertyAddress = inputVolumePropertyAddress(for: deviceID) else {
      return false
    }

    var mutableAddress = propertyAddress
    var isSettable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(deviceID, &mutableAddress, &isSettable) == noErr,
          isSettable.boolValue else {
      return false
    }

    var clampedVolume = Float32(min(max(volume, 0), 1))
    return AudioObjectSetPropertyData(
      deviceID,
      &mutableAddress,
      0,
      nil,
      UInt32(MemoryLayout<Float32>.size),
      &clampedVolume
    ) == noErr
  }

  private static func inputVolumePropertyAddress(for deviceID: AudioDeviceID) -> AudioObjectPropertyAddress? {
    let elements: [AudioObjectPropertyElement] = [
      1,
      kAudioObjectPropertyElementMain
    ]

    for element in elements {
      var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: element
      )

      if AudioObjectHasProperty(deviceID, &propertyAddress) {
        return propertyAddress
      }
    }

    return nil
  }
}

final class ThreadSafeAudioBuffer {
  private var buffer: [Float] = []
  private let lock = NSLock()

  func append(_ samples: [Float]) {
    lock.lock()
    defer { lock.unlock() }
    buffer.append(contentsOf: samples)
  }

  func clear(keepingCapacity: Bool = false) {
    lock.lock()
    defer { lock.unlock() }
    buffer.removeAll(keepingCapacity: keepingCapacity)
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return buffer.count
  }

  func getAll() -> [Float] {
    lock.lock()
    defer { lock.unlock() }
    return buffer
  }

  func drain(keepingCapacity: Bool = false) -> [Float] {
    lock.lock()
    defer { lock.unlock() }

    let drainedBuffer = buffer
    buffer.removeAll(keepingCapacity: keepingCapacity)
    return drainedBuffer
  }
}

class AudioRecorder: ObservableObject {
  typealias AudioLevelHandler = (Float) -> Void
  typealias RecordingFailureHandler = (Error) -> Void

  private var audioQueueRecorder: AudioQueueInputRecorder?
  private var capturePipeline: AudioCapturePipeline?
  private let audioBuffer = ThreadSafeAudioBuffer()
  private var onAudioLevel: AudioLevelHandler?
  private var onRecordingFailure: RecordingFailureHandler?
  private var recordingStartedAt: Date?
  private var selectedInputDevice: AudioInputDevice?
  private var activeBoundInputDevice: AudioInputDevice?
  private var audioRouteRecoveryTask: Task<Void, Never>?
  private var isRecoveringAudioRoute = false
  private var audioRouteChangesSuppressedUntil = Date.distantPast
  private var audioRouteRecoveryAttemptCount = 0
  private var audioRouteRecoveryWindowStartedAt: Date?
  private var activeRecordingID: UUID?
  private var initialCaptureWatchdogTask: Task<Void, Never>?
  private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
  private var monitoredDeviceID: AudioDeviceID?
  private var monitoredDeviceIsAliveListenerToken: AudioObjectPropertyListenerBlock?
  @Published private(set) var isRecording = false

  @discardableResult
  func startRecording(
    inputDevice: AudioInputDevice? = nil,
    onAudioLevel: AudioLevelHandler? = nil,
    onRecordingFailure: RecordingFailureHandler? = nil,
    boostInputVolume: Bool = false,
    startupTrace: RecordingStartupTrace? = nil
  ) async -> Bool {
    do {
      startupTrace?.event("audio_recorder_start_entered")
      prepareForNewRecordingStart()
      self.onAudioLevel = onAudioLevel
      self.onRecordingFailure = onRecordingFailure
      self.recordingStartedAt = Date()
      self.selectedInputDevice = inputDevice
      startupTrace?.event("audio_buffer_ready")

      if boostInputVolume {
        startupTrace?.event("input_volume_boost_begin")
        CoreAudioInputVolumeBoost.shared.apply(to: inputDevice?.deviceID)
        startupTrace?.event("input_volume_boost_finished")
      }

      let initialCaptureLatch = InitialAudioCaptureLatch()
      let recordingID = UUID()
      activeRecordingID = recordingID
      startupTrace?.event("audio_capture_backend_selected_audio_queue")
      startupTrace?.event("audio_queue_start_begin")
      try startAudioQueue(inputDevice: inputDevice, onInitialCapture: {
        initialCaptureLatch.signal()
      }, startupTrace: startupTrace)
      startupTrace?.event("audio_queue_start_returned")

      isRecording = true
      startMonitoringCurrentInputDevice()
      registerDefaultInputChangeListener()
      startInitialCaptureWatchdog(initialCaptureLatch, recordingID: recordingID)
      startupTrace?.event("audio_recorder_initial_capture_watchdog_started")
      startupTrace?.event("audio_recorder_start_complete")
      return true
    } catch {
      startupTrace?.event("audio_recorder_start_error")
      stopRecording(discardPendingAudio: true)
      audioBuffer.clear(keepingCapacity: true)
      clearRecordingState()
      print("Error starting recording: \(error.localizedDescription)")
      return false
    }
  }

  private func prepareForNewRecordingStart() {
    if isRecording {
      stopRecording(discardPendingAudio: true)
      return
    }

    audioRouteRecoveryTask?.cancel()
    audioRouteRecoveryTask = nil
    initialCaptureWatchdogTask?.cancel()
    initialCaptureWatchdogTask = nil
    isRecoveringAudioRoute = false
    resetAudioRouteRecoveryTracking()
    activeRecordingID = nil
    capturePipeline?.stopRecording(discardPendingAudio: true)
    audioBuffer.clear(keepingCapacity: true)
    audioQueueRecorder?.teardown()
    audioQueueRecorder = nil
  }

  func stopRecording(discardPendingAudio: Bool = false) {
    audioRouteRecoveryTask?.cancel()
    audioRouteRecoveryTask = nil
    initialCaptureWatchdogTask?.cancel()
    initialCaptureWatchdogTask = nil
    isRecoveringAudioRoute = false
    resetAudioRouteRecoveryTracking()
    activeRecordingID = nil
    isRecording = false
    if discardPendingAudio {
      capturePipeline?.stopRecording(discardPendingAudio: true)
      audioBuffer.clear(keepingCapacity: true)
      teardownAudioCapture()
    } else {
      capturePipeline?.stopRecording(discardPendingAudio: false)
      stopAudioQueueRecorder()
    }

    CoreAudioInputVolumeBoost.shared.restore()
  }

  func cancelRecording() {
    stopRecording(discardPendingAudio: true)
    audioBuffer.clear(keepingCapacity: true)
    clearRecordingState()
  }

  func getRecordedAudio() async -> Result<RecordedAudio, Error> {
    await capturePipeline?.flush()

    let drainStartedAt = CACurrentMediaTime()
    let samples = audioBuffer.drain(keepingCapacity: true)
    Self.logger.info("audio-drain samples=\(samples.count, privacy: .public) elapsed_ms=\(((CACurrentMediaTime() - drainStartedAt) * 1000), privacy: .public)")

    guard !samples.isEmpty else {
      clearRecordingState()
      return .failure(NSError(
        domain: "AudioRecorder",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "No audio was captured"]
      ))
    }

    let recordedAudio = await Self.makeRecordedAudio(from: samples)
    clearRecordingState()
    return .success(recordedAudio)
  }

  private func clearRecordingState() {
    recordingStartedAt = nil
    onAudioLevel = nil
    onRecordingFailure = nil
    selectedInputDevice = nil
    teardownAudioCapture()
    activeRecordingID = nil
    isRecording = false
  }

  private func startInitialCaptureWatchdog(_ latch: InitialAudioCaptureLatch, recordingID: UUID) {
    initialCaptureWatchdogTask?.cancel()
    initialCaptureWatchdogTask = Task { [weak self] in
      let didCapture = await latch.wait(timeoutNanoseconds: Self.initialCaptureTimeoutNanoseconds)

      await MainActor.run { [weak self] in
        guard let self,
              self.activeRecordingID == recordingID,
              self.isRecording else {
          return
        }

        self.initialCaptureWatchdogTask = nil

        guard didCapture else {
          Self.logger.error("audio-initial-capture-timeout")
          let error = NSError(
            domain: "AudioRecorder",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Audio input did not begin delivering samples."]
          )
          self.stopRecordingAfterCaptureFailure(error)
          return
        }

        Self.logger.info("audio-initial-capture-received")
      }
    }
  }

  private func startAudioQueue(
    inputDevice: AudioInputDevice?,
    onInitialCapture: (() -> Void)?,
    startupTrace: RecordingStartupTrace?
  ) throws {
    teardownAudioCapture()

    let pipeline = AudioCapturePipeline(
      audioBuffer: audioBuffer,
      onAudioLevel: onAudioLevel,
      onInitialCapture: onInitialCapture
    )
    pipeline.beginRecording(
      onAudioLevel: onAudioLevel,
      onInitialCapture: onInitialCapture
    )
    capturePipeline = pipeline

    let explicitlyBoundInputDevice = inputDeviceNeedingExplicitBinding(inputDevice)
    let recorder = AudioQueueInputRecorder(
      pipeline: pipeline,
      onFailure: { [weak self] error in
        DispatchQueue.main.async {
          self?.stopRecordingAfterCaptureFailure(error)
        }
      }
    )
    audioQueueRecorder = recorder

    try recorder.start(
      requestedInputDevice: inputDevice,
      explicitlyBoundInputDevice: explicitlyBoundInputDevice,
      startupTrace: startupTrace
    )
    setActiveInputBinding(explicitlyBoundInputDevice)
    Self.logger.info("audio-queue-started")
  }

  private func stopAudioQueueRecorder(startupTrace: RecordingStartupTrace? = nil) {
    audioQueueRecorder?.stop(startupTrace: startupTrace)
    audioQueueRecorder = nil
  }

  private func inputDeviceNeedingExplicitBinding(
    _ inputDevice: AudioInputDevice?,
    logDefaultSkip: Bool = true
  ) -> AudioInputDevice? {
    guard let inputDevice else {
      return nil
    }

    guard AudioInputDevice.currentDefaultInputDeviceID() != inputDevice.deviceID else {
      if logDefaultSkip {
        Self.logger.info("audio-input-bind-skipped device=\(inputDevice.name, privacy: .public) reason=already-default")
      }
      return nil
    }

    return inputDevice
  }

  private func setActiveInputBinding(_ inputDevice: AudioInputDevice?) {
    activeBoundInputDevice = inputDevice
  }

  private func teardownAudioCapture(discardPipeline: Bool = true) {
    audioQueueRecorder?.teardown()
    audioQueueRecorder = nil

    if discardPipeline {
      capturePipeline?.invalidate()
      capturePipeline = nil
    }

    unregisterDefaultInputChangeListener()
    stopMonitoringDevice()
    activeBoundInputDevice = nil
  }

  private func registerDefaultInputChangeListener() {
    guard defaultInputListenerToken == nil else {
      return
    }

    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self,
              self.activeBoundInputDevice == nil else {
          return
        }

        if self.isRecording {
          self.scheduleAudioRouteRecovery(reason: "default input changed")
        } else {
          self.teardownAudioCapture()
        }
      }
    }

    guard AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      DispatchQueue.main,
      token
    ) == noErr else {
      return
    }

    defaultInputListenerToken = token
  }

  private func unregisterDefaultInputChangeListener() {
    guard let defaultInputListenerToken else {
      return
    }

    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      DispatchQueue.main,
      defaultInputListenerToken
    )
    self.defaultInputListenerToken = nil
  }

  private func scheduleAudioRouteRecovery(reason: String) {
    guard isRecording, !isRecoveringAudioRoute else {
      return
    }

    guard audioRouteRecoveryTask == nil else {
      Self.logger.info("audio-route-recovery-already-pending reason=\(reason, privacy: .public)")
      return
    }

    guard Date() >= audioRouteChangesSuppressedUntil else {
      Self.logger.info("audio-route-recovery-suppressed reason=\(reason, privacy: .public)")
      return
    }

    Self.logger.warning("audio-route-recovery-scheduled reason=\(reason, privacy: .public)")
    capturePipeline?.stopRecording(discardPendingAudio: false)
    onAudioLevel?(0)
    audioRouteRecoveryTask?.cancel()
    audioRouteRecoveryTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.audioRouteRecoveryDelayNanoseconds)
      } catch {
        return
      }

      await self?.recoverAudioRouteOnMainActor(reason: reason)
    }
  }

  @MainActor
  private func recoverAudioRouteOnMainActor(reason: String) {
    recoverAudioRoute(reason: reason)
  }

  private func recoverAudioRoute(reason: String) {
    guard isRecording, !isRecoveringAudioRoute else {
      return
    }

    guard recordAudioRouteRecoveryAttempt() else {
      let error = NSError(
        domain: "AudioRecorder",
        code: 9,
        userInfo: [NSLocalizedDescriptionKey: "Audio input route changed repeatedly and recording could not stabilize."]
      )
      Self.logger.error("audio-route-recovery-limit-reached reason=\(reason, privacy: .public)")
      stopRecordingAfterCaptureFailure(error)
      return
    }

    isRecoveringAudioRoute = true
    defer {
      isRecoveringAudioRoute = false
      audioRouteRecoveryTask = nil
    }

    Self.logger.info("audio-route-recovery-start reason=\(reason, privacy: .public)")
    suppressAudioRouteChanges()
    stopMonitoringDevice()
    teardownAudioCapture()

    do {
      try startAudioQueue(
        inputDevice: selectedInputDevice,
        onInitialCapture: nil,
        startupTrace: nil
      )
      startMonitoringCurrentInputDevice()
      registerDefaultInputChangeListener()
      suppressAudioRouteChanges()
      Self.logger.info("audio-route-recovery-success reason=\(reason, privacy: .public)")
    } catch {
      Self.logger.error("audio-route-recovery-failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
      stopRecordingAfterCaptureFailure(error)
    }
  }

  private func suppressAudioRouteChanges() {
    audioRouteChangesSuppressedUntil = Date().addingTimeInterval(Self.audioRouteChangeSuppressionInterval)
  }

  private func resetAudioRouteRecoveryTracking() {
    audioRouteChangesSuppressedUntil = Date.distantPast
    audioRouteRecoveryAttemptCount = 0
    audioRouteRecoveryWindowStartedAt = nil
  }

  private func recordAudioRouteRecoveryAttempt() -> Bool {
    let now = Date()
    if let windowStartedAt = audioRouteRecoveryWindowStartedAt,
       now.timeIntervalSince(windowStartedAt) <= Self.audioRouteRecoveryAttemptWindow {
      audioRouteRecoveryAttemptCount += 1
    } else {
      audioRouteRecoveryWindowStartedAt = now
      audioRouteRecoveryAttemptCount = 1
    }

    return audioRouteRecoveryAttemptCount <= Self.maximumAudioRouteRecoveryAttempts
  }

  private func stopRecordingAfterCaptureFailure(_ error: Error) {
    let recordingFailureHandler = onRecordingFailure
    stopRecording(discardPendingAudio: true)
    audioBuffer.clear(keepingCapacity: true)
    clearRecordingState()

    DispatchQueue.main.async {
      recordingFailureHandler?(error)
    }
  }

  private func startMonitoringCurrentInputDevice() {
    let deviceID = selectedInputDevice?.deviceID ?? AudioInputDevice.currentDefaultInputDeviceID()
    guard let deviceID else {
      return
    }

    startMonitoringDevice(deviceID)
  }

  private func startMonitoringDevice(_ deviceID: AudioDeviceID) {
    stopMonitoringDevice()

    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.handleDeviceAvailabilityChanged(deviceID: deviceID)
      }
    }

    guard AudioObjectAddPropertyListenerBlock(deviceID, &propertyAddress, DispatchQueue.main, token) == noErr else {
      return
    }

    monitoredDeviceID = deviceID
    monitoredDeviceIsAliveListenerToken = token
  }

  private func stopMonitoringDevice() {
    guard let monitoredDeviceID else {
      return
    }

    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    if let monitoredDeviceIsAliveListenerToken {
      AudioObjectRemovePropertyListenerBlock(
        monitoredDeviceID,
        &propertyAddress,
        DispatchQueue.main,
        monitoredDeviceIsAliveListenerToken
      )
    }

    self.monitoredDeviceID = nil
    self.monitoredDeviceIsAliveListenerToken = nil
  }

  private func handleDeviceAvailabilityChanged(deviceID: AudioDeviceID) {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var isAlive: UInt32 = 0
    var propertySize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &isAlive)

    if status == noErr, isAlive == 0 {
      if isRecording {
        scheduleAudioRouteRecovery(reason: "input device disconnected")
      } else {
        teardownAudioCapture()
      }
    }
  }

  deinit {
    unregisterDefaultInputChangeListener()
    stopRecording(discardPendingAudio: true)
    CoreAudioInputVolumeBoost.shared.restore()
    clearRecordingState()
  }

  static func transcriptionFormat() -> AVAudioFormat {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16000,
      channels: 1,
      interleaved: false
    )!
  }

  static func applySpeechGain(to samples: UnsafeMutablePointer<Float>, frameCount: Int) {
    guard frameCount > 0 else {
      return
    }

    let rms = rootMeanSquare(from: samples, frameCount: frameCount)
    guard rms > speechGainSilenceFloor else {
      return
    }

    let gain = min(max(targetSpeechRMS / rms, minimumSpeechGain), maximumSpeechGain)

    var mutableGain = gain
    vDSP_vsmul(samples, 1, &mutableGain, samples, 1, vDSP_Length(frameCount))

    var lowerLimit = -limiterThreshold
    var upperLimit = limiterThreshold
    vDSP_vclip(samples, 1, &lowerLimit, &upperLimit, samples, 1, vDSP_Length(frameCount))
  }

  private static func rootMeanSquare(from samples: UnsafePointer<Float>, frameCount: Int) -> Float {
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
    return rms
  }

  private static func makeRecordedAudio(from samples: [Float]) async -> RecordedAudio {
    await Task.detached(priority: .userInitiated) {
      let processStartedAt = CACurrentMediaTime()
      var mutableSamples = samples
      mutableSamples.withUnsafeMutableBufferPointer { buffer in
        if let baseAddress = buffer.baseAddress {
          applySpeechGain(to: baseAddress, frameCount: buffer.count)
        }
      }
      logger.info("audio-normalize samples=\(mutableSamples.count, privacy: .public) elapsed_ms=\(((CACurrentMediaTime() - processStartedAt) * 1000), privacy: .public)")

      let sampleRate = transcriptionFormat().sampleRate
      let pcmData = mutableSamples.withUnsafeBufferPointer { Data(buffer: $0) }
      return RecordedAudio(
        pcmData: pcmData,
        sampleRate: sampleRate,
        duration: Double(mutableSamples.count) / sampleRate
      )
    }.value
  }

  private static let targetSpeechRMS: Float = 0.08
  private static let minimumSpeechGain: Float = 1.0
  private static let maximumSpeechGain: Float = 6.0
  private static let speechGainSilenceFloor: Float = 0.0015
  private static let limiterThreshold: Float = 0.98
  private static let initialCaptureTimeoutNanoseconds: UInt64 = 1_500_000_000
  private static let audioRouteRecoveryDelayNanoseconds: UInt64 = 1_000_000_000
  private static let audioRouteChangeSuppressionInterval: TimeInterval = 2
  private static let audioRouteRecoveryAttemptWindow: TimeInterval = 10
  private static let maximumAudioRouteRecoveryAttempts = 3
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.chirpapp.Chirp", category: "AudioRecorder")
}

private final class InitialAudioCaptureLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var didSignal = false
  private var continuation: CheckedContinuation<Bool, Never>?

  func signal() {
    let continuationToResume: CheckedContinuation<Bool, Never>?

    lock.lock()
    if didSignal {
      continuationToResume = nil
    } else {
      didSignal = true
      continuationToResume = continuation
      continuation = nil
    }
    lock.unlock()

    continuationToResume?.resume(returning: true)
  }

  func wait(timeoutNanoseconds: UInt64) async -> Bool {
    await withCheckedContinuation { continuation in
      lock.lock()
      if didSignal {
        lock.unlock()
        continuation.resume(returning: true)
        return
      }

      self.continuation = continuation
      lock.unlock()

      DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))) { [weak self] in
        self?.timeOut()
      }
    }
  }

  private func timeOut() {
    let continuationToResume: CheckedContinuation<Bool, Never>?

    lock.lock()
    if didSignal {
      continuationToResume = nil
    } else {
      didSignal = true
      continuationToResume = continuation
      continuation = nil
    }
    lock.unlock()

    continuationToResume?.resume(returning: false)
  }
}

private final class AudioQueueInputRecorder {
  private let pipeline: AudioCapturePipeline
  private let onFailure: (Error) -> Void
  private let lock = NSLock()

  private var audioQueue: AudioQueueRef?
  private var buffers: [AudioQueueBufferRef] = []
  private var streamDescription = AudioStreamBasicDescription()
  private var audioFormat: AVAudioFormat?
  private var startupTrace: RecordingStartupTrace?
  private var isRecording = false
  private var didTraceFirstBuffer = false
  private var didReportFailure = false

  init(
    pipeline: AudioCapturePipeline,
    onFailure: @escaping (Error) -> Void
  ) {
    self.pipeline = pipeline
    self.onFailure = onFailure
  }

  func start(
    requestedInputDevice: AudioInputDevice?,
    explicitlyBoundInputDevice: AudioInputDevice?,
    startupTrace: RecordingStartupTrace?
  ) throws {
    teardown()
    startupTrace?.event("audio_queue_prepare_begin")

    let queueFormat = Self.preferredInputFormat(for: requestedInputDevice)
    var mutableQueueFormat = queueFormat
    var queue: AudioQueueRef?
    let createStatus = AudioQueueNewInput(
      &mutableQueueFormat,
      Self.inputCallback,
      Unmanaged.passUnretained(self).toOpaque(),
      nil,
      nil,
      0,
      &queue
    )
    guard createStatus == noErr, let queue else {
      throw Self.error(status: createStatus, message: "Failed to create Audio Queue input")
    }
    startupTrace?.event("audio_queue_created")

    do {
      if let explicitlyBoundInputDevice {
        try bind(explicitlyBoundInputDevice, to: queue)
      }

      var resolvedFormat = queueFormat
      var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let formatStatus = AudioQueueGetProperty(
        queue,
        kAudioQueueProperty_StreamDescription,
        &resolvedFormat,
        &propertySize
      )
      if formatStatus != noErr {
        Self.logger.warning("audio-queue-format-query-failed status=\(formatStatus, privacy: .public)")
      }

      var avFormatDescription = resolvedFormat
      guard let avFormat = AVAudioFormat(streamDescription: &avFormatDescription) else {
        throw Self.error(status: kAudio_ParamError, message: "Failed to create AVAudioFormat for Audio Queue input")
      }

      let bufferByteSize = Self.bufferByteSize(for: resolvedFormat)
      var allocatedBuffers: [AudioQueueBufferRef] = []
      for _ in 0..<Self.bufferCount {
        var buffer: AudioQueueBufferRef?
        let allocateStatus = AudioQueueAllocateBuffer(queue, bufferByteSize, &buffer)
        guard allocateStatus == noErr, let buffer else {
          throw Self.error(status: allocateStatus, message: "Failed to allocate Audio Queue input buffer")
        }

        let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        guard enqueueStatus == noErr else {
          throw Self.error(status: enqueueStatus, message: "Failed to enqueue Audio Queue input buffer")
        }
        allocatedBuffers.append(buffer)
      }

      lock.lock()
      self.audioQueue = queue
      self.buffers = allocatedBuffers
      self.streamDescription = resolvedFormat
      self.audioFormat = avFormat
      self.startupTrace = startupTrace
      self.isRecording = true
      self.didTraceFirstBuffer = false
      self.didReportFailure = false
      lock.unlock()
      startupTrace?.event("audio_queue_buffers_enqueued")

      startupTrace?.event("audio_queue_start_call_begin")
      let startStatus = AudioQueueStart(queue, nil)
      startupTrace?.event("audio_queue_start_call_returned")
      guard startStatus == noErr else {
        throw Self.error(status: startStatus, message: "Failed to start Audio Queue input")
      }

      Self.logger.info(
        "audio-queue-started sample_rate=\(resolvedFormat.mSampleRate, privacy: .public) channels=\(resolvedFormat.mChannelsPerFrame, privacy: .public) bytes_per_frame=\(resolvedFormat.mBytesPerFrame, privacy: .public)"
      )
    } catch {
      AudioQueueDispose(queue, true)
      lock.lock()
      self.audioQueue = nil
      self.buffers.removeAll()
      self.audioFormat = nil
      self.startupTrace = nil
      self.isRecording = false
      lock.unlock()
      throw error
    }
  }

  func stop(startupTrace: RecordingStartupTrace? = nil) {
    let queue: AudioQueueRef?

    lock.lock()
    queue = audioQueue
    audioQueue = nil
    buffers.removeAll()
    audioFormat = nil
    self.startupTrace = nil
    isRecording = false
    lock.unlock()

    guard let queue else {
      return
    }

    startupTrace?.event("audio_queue_stop_begin")
    let stopStatus = AudioQueueStop(queue, true)
    if stopStatus != noErr {
      Self.logger.warning("audio-queue-stop-failed status=\(stopStatus, privacy: .public)")
    }
    startupTrace?.event("audio_queue_stop_returned")

    let disposeStatus = AudioQueueDispose(queue, true)
    if disposeStatus != noErr {
      Self.logger.warning("audio-queue-dispose-failed status=\(disposeStatus, privacy: .public)")
    }
    startupTrace?.event("audio_queue_disposed")
    Self.logger.info("audio-queue-stopped-disposed")
  }

  func teardown() {
    stop()
  }

  private func bind(_ inputDevice: AudioInputDevice, to queue: AudioQueueRef) throws {
    let deviceUID = inputDevice.uid as CFString
    var deviceUIDReference = Unmanaged.passUnretained(deviceUID).toOpaque()
    let status = AudioQueueSetProperty(
      queue,
      kAudioQueueProperty_CurrentDevice,
      &deviceUIDReference,
      UInt32(MemoryLayout.size(ofValue: deviceUIDReference))
    )

    guard status == noErr else {
      Self.logger.warning("audio-queue-input-bind-failed device=\(inputDevice.name, privacy: .public) status=\(status, privacy: .public)")
      throw Self.error(status: status, message: "Failed to bind Audio Queue input device: \(inputDevice.name)")
    }

    Self.logger.info("audio-queue-input-bound device=\(inputDevice.name, privacy: .public)")
  }

  private func handleInputBuffer(
    queue: AudioQueueRef,
    buffer: AudioQueueBufferRef,
    packetCount: UInt32
  ) {
    let shouldCapture: Bool
    let format: AVAudioFormat?
    let bytesPerFrame: UInt32
    let traceForFirstBuffer: RecordingStartupTrace?

    lock.lock()
    shouldCapture = isRecording && audioQueue != nil
    format = audioFormat
    bytesPerFrame = streamDescription.mBytesPerFrame
    if shouldCapture, !didTraceFirstBuffer {
      didTraceFirstBuffer = true
      traceForFirstBuffer = startupTrace
    } else {
      traceForFirstBuffer = nil
    }
    lock.unlock()

    if shouldCapture,
       let format,
       buffer.pointee.mAudioDataByteSize > 0,
       bytesPerFrame > 0 {
      traceForFirstBuffer?.event("audio_queue_first_buffer_received")

      let sourceData = buffer.pointee.mAudioData
      let byteCount = Int(buffer.pointee.mAudioDataByteSize)
      let computedFrameCount = byteCount / Int(bytesPerFrame)
      let frameCount = AVAudioFrameCount(packetCount > 0 ? Int(packetCount) : computedFrameCount)
      let data = Data(bytes: sourceData, count: byteCount)
      pipeline.handle(pcmData: data, format: format, frameLength: frameCount)
    }

    lock.lock()
    let shouldReenqueue = isRecording && audioQueue != nil
    lock.unlock()

    guard shouldReenqueue else {
      return
    }

    let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    if enqueueStatus != noErr {
      reportFailureOnce(Self.error(status: enqueueStatus, message: "Failed to re-enqueue Audio Queue input buffer"))
    }
  }

  private func reportFailureOnce(_ error: Error) {
    let shouldReport: Bool

    lock.lock()
    shouldReport = !didReportFailure
    didReportFailure = true
    lock.unlock()

    if shouldReport {
      onFailure(error)
    }
  }

  private static func preferredInputFormat(for inputDevice: AudioInputDevice?) -> AudioStreamBasicDescription {
    let deviceID = inputDevice?.deviceID ?? AudioInputDevice.currentDefaultInputDeviceID()
    let sampleRate = deviceID.flatMap(AudioInputDevice.nominalSampleRate(for:)) ?? 48_000
    let channels = max(1, deviceID.flatMap(AudioInputDevice.inputChannelCount(for:)) ?? 1)
    let bytesPerSample = UInt32(MemoryLayout<Float>.size)
    let bytesPerFrame = bytesPerSample * channels

    return AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: channels,
      mBitsPerChannel: bytesPerSample * 8,
      mReserved: 0
    )
  }

  private static func bufferByteSize(for format: AudioStreamBasicDescription) -> UInt32 {
    let frames = max(1, UInt32((format.mSampleRate * bufferDuration).rounded(.up)))
    return max(format.mBytesPerFrame * frames, 4_096)
  }

  private static func error(status: OSStatus, message: String) -> NSError {
    NSError(
      domain: "AudioQueueInputRecorder",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "\(message) (status \(status))"]
    )
  }

  private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, packetCount, _ in
    guard let userData else {
      return
    }

    let recorder = Unmanaged<AudioQueueInputRecorder>.fromOpaque(userData).takeUnretainedValue()
    recorder.handleInputBuffer(queue: queue, buffer: buffer, packetCount: packetCount)
  }

  private static let bufferCount = 4
  private static let bufferDuration: Double = 0.02
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.chirpapp.Chirp", category: "AudioQueueInputRecorder")
}

private final class AudioCapturePipeline {
  private let audioBuffer: ThreadSafeAudioBuffer
  private let targetFormat = AudioRecorder.transcriptionFormat()
  private let processingQueue = DispatchQueue(label: "com.chirpapp.Chirp.audio-capture-pipeline", qos: .userInitiated)
  private let lock = NSLock()

  private var onAudioLevel: AudioRecorder.AudioLevelHandler?
  private var onInitialCapture: (() -> Void)?
  private var recordingEnabled = false
  private var invalidated = false
  private var pendingBufferCount = 0
  private var recordingGeneration: UInt64 = 0
  private var didPublishInitialCapture = false
  private var levelHistory: [Float] = []
  private var smoothedLevel: Float = 0
  private var lastLevelPublishTime: CFTimeInterval = 0
  private var converter: AVAudioConverter?
  private var converterInputSignature: String?

  init(
    audioBuffer: ThreadSafeAudioBuffer,
    onAudioLevel: AudioRecorder.AudioLevelHandler?,
    onInitialCapture: (() -> Void)? = nil
  ) {
    self.audioBuffer = audioBuffer
    self.onAudioLevel = onAudioLevel
    self.onInitialCapture = onInitialCapture
  }

  func beginRecording(
    onAudioLevel: AudioRecorder.AudioLevelHandler?,
    onInitialCapture: (() -> Void)? = nil
  ) {
    lock.lock()
    recordingGeneration &+= 1
    recordingEnabled = true
    self.onAudioLevel = onAudioLevel
    self.onInitialCapture = onInitialCapture
    didPublishInitialCapture = false
    levelHistory.removeAll(keepingCapacity: true)
    smoothedLevel = 0
    lastLevelPublishTime = 0
    lock.unlock()
  }

  func stopRecording(discardPendingAudio: Bool = false) {
    lock.lock()
    let shouldPublishStoppedLevel = recordingEnabled && !invalidated
    recordingEnabled = false
    if discardPendingAudio {
      recordingGeneration &+= 1
    }
    onInitialCapture = nil
    levelHistory.removeAll(keepingCapacity: true)
    smoothedLevel = 0
    lock.unlock()

    if shouldPublishStoppedLevel {
      publishLevel(0, force: true)
    }
  }

  func clearHandlers() {
    lock.lock()
    onAudioLevel = nil
    onInitialCapture = nil
    lock.unlock()
  }

  func invalidate() {
    lock.lock()
    let shouldPublishStoppedLevel = recordingEnabled
    invalidated = true
    recordingEnabled = false
    recordingGeneration &+= 1
    onInitialCapture = nil
    levelHistory.removeAll(keepingCapacity: true)
    smoothedLevel = 0
    lock.unlock()

    if shouldPublishStoppedLevel {
      publishLevel(0, force: true)
    }
  }

  func flush() async {
    await withCheckedContinuation { continuation in
      processingQueue.async {
        continuation.resume()
      }
    }
  }

  func handle(buffer: AVAudioPCMBuffer) {
    guard let generation = reservePendingBufferSlot() else {
      return
    }

    guard let copiedBuffer = Self.copy(buffer) else {
      releasePendingBufferSlot()
      return
    }

    processingQueue.async { [self] in
      defer {
        releasePendingBufferSlot()
      }

      process(buffer: copiedBuffer, generation: generation)
    }
  }

  func handle(pcmData: Data, format: AVAudioFormat, frameLength: AVAudioFrameCount) {
    guard let generation = reservePendingBufferSlot() else {
      return
    }

    processingQueue.async { [self] in
      defer {
        releasePendingBufferSlot()
      }

      guard let buffer = Self.makePCMBuffer(
        pcmData: pcmData,
        format: format,
        frameLength: frameLength
      ) else {
        return
      }

      process(buffer: buffer, generation: generation)
    }
  }

  private func process(buffer: AVAudioPCMBuffer, generation: UInt64) {
    guard !isInvalidated else {
      return
    }

    let samples = convertToMono16k(buffer)
    guard !samples.isEmpty else {
      if shouldPublishLevels {
        publishLevel(0)
      }
      return
    }

    guard appendIfValid(samples, generation: generation) else {
      return
    }

    publishInitialCaptureIfNeeded()
    if shouldPublishLevels {
      publishLevel(normalizedLevel(for: samples))
    }
  }

  private var shouldPublishLevels: Bool {
    lock.lock()
    defer { lock.unlock() }

    return recordingEnabled && !invalidated
  }

  private var isInvalidated: Bool {
    lock.lock()
    defer { lock.unlock() }

    return invalidated
  }

  private func reservePendingBufferSlot() -> UInt64? {
    lock.lock()
    defer { lock.unlock() }

    guard recordingEnabled,
          !invalidated,
          pendingBufferCount < Self.maximumPendingBuffers else {
      return nil
    }

    pendingBufferCount += 1
    return recordingGeneration
  }

  private func releasePendingBufferSlot() {
    lock.lock()
    pendingBufferCount = max(0, pendingBufferCount - 1)
    lock.unlock()
  }

  private func appendIfValid(_ samples: [Float], generation: UInt64) -> Bool {
    lock.lock()
    guard !invalidated,
          generation == recordingGeneration else {
      lock.unlock()
      return false
    }

    audioBuffer.append(samples)
    lock.unlock()
    return true
  }

  private func publishInitialCaptureIfNeeded() {
    let shouldPublish: Bool
    let handler: (() -> Void)?

    lock.lock()
    shouldPublish = !didPublishInitialCapture
    didPublishInitialCapture = true
    handler = onInitialCapture
    lock.unlock()

    if shouldPublish {
      handler?()
    }
  }

  private func publishLevel(_ level: Float, force: Bool = false) {
    let shouldPublish: Bool
    let now = CACurrentMediaTime()

    lock.lock()
    if force || now - lastLevelPublishTime >= Self.minimumLevelPublishInterval {
      lastLevelPublishTime = now
      shouldPublish = true
    } else {
      shouldPublish = false
    }
    lock.unlock()

    guard shouldPublish else {
      return
    }

    let handler: AudioRecorder.AudioLevelHandler?
    lock.lock()
    handler = onAudioLevel
    lock.unlock()

    DispatchQueue.main.async {
      handler?(level)
    }
  }

  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copiedBuffer = AVAudioPCMBuffer(
      pcmFormat: buffer.format,
      frameCapacity: buffer.frameLength
    ) else {
      return nil
    }

    copiedBuffer.frameLength = buffer.frameLength
    let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)

    for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
      let sourceBuffer = sourceBuffers[index]
      guard let sourceData = sourceBuffer.mData,
            let destinationData = destinationBuffers[index].mData else {
        continue
      }

      memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
      destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
    }

    return copiedBuffer
  }

  private static func makePCMBuffer(
    pcmData: Data,
    format: AVAudioFormat,
    frameLength: AVAudioFrameCount
  ) -> AVAudioPCMBuffer? {
    guard frameLength > 0,
          !pcmData.isEmpty,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
      return nil
    }

    buffer.frameLength = frameLength
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    var bytesCopied = 0

    pcmData.withUnsafeBytes { sourceBytes in
      guard let sourceBaseAddress = sourceBytes.baseAddress else {
        return
      }

      for destinationBufferIndex in 0..<destinationBuffers.count {
        var destinationBuffer = destinationBuffers[destinationBufferIndex]
        guard let destinationData = destinationBuffer.mData else {
          continue
        }

        let remainingByteCount = pcmData.count - bytesCopied
        guard remainingByteCount > 0 else {
          destinationBuffer.mDataByteSize = 0
          destinationBuffers[destinationBufferIndex] = destinationBuffer
          continue
        }

        let copyByteCount = min(Int(destinationBuffer.mDataByteSize), remainingByteCount)
        memcpy(destinationData, sourceBaseAddress.advanced(by: bytesCopied), copyByteCount)
        destinationBuffer.mDataByteSize = UInt32(copyByteCount)
        destinationBuffers[destinationBufferIndex] = destinationBuffer
        bytesCopied += copyByteCount
      }
    }

    return buffer
  }

  private func convertToMono16k(_ buffer: AVAudioPCMBuffer) -> [Float] {
    if buffer.format.sampleRate == targetFormat.sampleRate,
       buffer.format.commonFormat == .pcmFormatFloat32,
       buffer.format.channelCount == targetFormat.channelCount,
       let channelData = buffer.floatChannelData {
      return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    guard let convertedBuffer = convert(buffer, to: targetFormat),
          let channelData = convertedBuffer.floatChannelData else {
      return []
    }

    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))
  }

  private func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    let inputFormat = buffer.format
    let signature = "\(inputFormat.commonFormat.rawValue)-\(inputFormat.sampleRate)-\(inputFormat.channelCount)-\(inputFormat.isInterleaved)"

    lock.lock()
    if converter == nil || converterInputSignature != signature {
      converter = AVAudioConverter(from: inputFormat, to: targetFormat)
      converterInputSignature = signature
    }
    let activeConverter = converter
    lock.unlock()

    guard let activeConverter else {
      return nil
    }

    let sampleRateRatio = targetFormat.sampleRate / inputFormat.sampleRate
    let outputCapacity = AVAudioFrameCount((Double(buffer.frameLength) * sampleRateRatio).rounded(.up)) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
      return nil
    }

    var didProvideInput = false
    var conversionError: NSError?
    let status = activeConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
      if didProvideInput {
        inputStatus.pointee = .noDataNow
        return nil
      }

      didProvideInput = true
      inputStatus.pointee = .haveData
      return buffer
    }

    guard conversionError == nil, status != .error else {
      return nil
    }

    return outputBuffer
  }

  private func normalizedLevel(for samples: [Float]) -> Float {
    guard !samples.isEmpty else {
      return 0
    }

    var sum: Float = 0
    vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
    let rms = sqrt(sum / Float(samples.count))
    guard rms >= Self.levelSilenceFloor else {
      return smoothed(0)
    }

    let decibels = 20 * log10(max(rms, 1e-10))
    let normalized = min(max((decibels + 55) / 55, 0), 1)
    return smoothed(normalized)
  }

  private func smoothed(_ level: Float) -> Float {
    lock.lock()
    defer { lock.unlock() }

    levelHistory.append(level)
    if levelHistory.count > Self.levelHistorySize {
      levelHistory.removeFirst(levelHistory.count - Self.levelHistorySize)
    }

    let average = levelHistory.reduce(0, +) / Float(levelHistory.count)
    smoothedLevel = Self.levelSmoothingFactor * level + (1 - Self.levelSmoothingFactor) * average
    return smoothedLevel < Self.levelDisplayThreshold ? 0 : smoothedLevel
  }

  private static let levelHistorySize = 2
  private static let levelSmoothingFactor: Float = 0.7
  private static let levelSilenceFloor: Float = 0.002
  private static let levelDisplayThreshold: Float = 0.04
  private static let maximumPendingBuffers = 12
  private static let minimumLevelPublishInterval: CFTimeInterval = 1.0 / 30.0
}
