//
//  AppleSpeechTranscriberTests.swift
//  ChirpTests
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import Chirp

struct AppleSpeechTranscriberTests {
  @Test func recordedAudioCreatesFloatPCMBufferWithoutAFileHop() throws {
    let samples: [Float] = [0, 0.25, -0.5, 1.0]
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let recordedAudio = RecordedAudio(
      pcmData: data,
      sampleRate: 16_000,
      duration: 0.25
    )

    let buffer = try AppleSpeechTranscriber.makePCMBuffer(from: recordedAudio)

    #expect(buffer.frameLength == AVAudioFrameCount(samples.count))
    #expect(buffer.format.sampleRate == 16_000)
    #expect(buffer.format.channelCount == 1)
    #expect(Array(UnsafeBufferPointer(start: buffer.floatChannelData?.pointee, count: samples.count)) == samples)
  }

  @Test func emptyRecordedAudioThrows() {
    let recordedAudio = RecordedAudio(
      pcmData: Data(),
      sampleRate: 16_000,
      duration: 0
    )

    #expect(throws: AppleSpeechTranscriptionError.emptyAudio) {
      try AppleSpeechTranscriber.makePCMBuffer(from: recordedAudio)
    }
  }

  @Test func malformedRecordedAudioThrows() {
    let recordedAudio = RecordedAudio(
      pcmData: Data([0, 1, 2]),
      sampleRate: 16_000,
      duration: 0
    )

    #expect(throws: AppleSpeechTranscriptionError.invalidAudio) {
      try AppleSpeechTranscriber.makePCMBuffer(from: recordedAudio)
    }
  }

  @Test func appleSpeechErrorsDescribeEmptyAudioAndOutput() {
    #expect(AppleSpeechTranscriptionError.emptyAudio.errorDescription == "No audio was captured.")
    #expect(AppleSpeechTranscriptionError.emptyOutput.errorDescription == "Apple Speech returned an empty transcription.")
  }

  @Test func normalizedTextTrimsWhitespace() throws {
    #expect(try AppleSpeechTranscriber.normalizedText(from: "  Hello world.\n") == "Hello world.")
  }

  @Test func automaticInputPrefersBuiltInMicOverBluetooth() {
    let bluetoothInput = AudioInputDevice(
      deviceID: 1,
      uid: "airpods",
      name: "AirPods",
      transportType: kAudioDeviceTransportTypeBluetooth,
      isDefault: true
    )
    let builtInInput = AudioInputDevice(
      deviceID: 2,
      uid: "built-in",
      name: "MacBook Pro Microphone",
      transportType: kAudioDeviceTransportTypeBuiltIn,
      isDefault: false
    )

    #expect(AudioInputDevice.bestAutomaticDevice(in: [bluetoothInput, builtInInput]) == builtInInput)
  }

  @Test func explicitInputSelectionWinsWhenAvailable() {
    let builtInInput = AudioInputDevice(
      deviceID: 2,
      uid: "built-in",
      name: "MacBook Pro Microphone",
      transportType: kAudioDeviceTransportTypeBuiltIn,
      isDefault: true
    )
    let usbInput = AudioInputDevice(
      deviceID: 3,
      uid: "usb",
      name: "Studio Mic",
      transportType: kAudioDeviceTransportTypeUSB,
      isDefault: false
    )

    #expect(AudioInputDevice.resolvedDevice(for: "usb", in: [builtInInput, usbInput]) == usbInput)
  }

  @Test func recordingShortcutPressStateKeepsTokenStableUntilRelease() {
    let pressState = RecordingShortcutPressState()

    let firstPressToken = pressState.pressBegan()
    let repeatedPressToken = pressState.pressBegan()

    #expect(repeatedPressToken == firstPressToken)
    #expect(pressState.isPressActive(firstPressToken))

    pressState.pressEnded()
    #expect(!pressState.isPressActive(firstPressToken))

    let secondPressToken = pressState.pressBegan()
    #expect(secondPressToken != firstPressToken)
    #expect(pressState.isPressActive(secondPressToken))
  }
}
