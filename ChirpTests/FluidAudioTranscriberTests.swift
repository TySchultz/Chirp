//
//  FluidAudioTranscriberTests.swift
//  ChirpTests
//
//

import Foundation
import CoreAudio
import Testing
@testable import Chirp

struct FluidAudioTranscriberTests {
  @Test func recordedAudioDecodesFloatSamplesWithoutAFileHop() {
    let samples: [Float] = [0, 0.25, -0.5, 1.0]
    let data = samples.withUnsafeBufferPointer { buffer in
      Data(buffer: buffer)
    }
    let recordedAudio = RecordedAudio(
      pcmData: data,
      sampleRate: 16_000,
      duration: 0.25
    )

    #expect(recordedAudio.floatSamples() == samples)
    #expect(recordedAudio.sampleCount == samples.count)
  }

  @Test func recordedAudioReturnsNoSamplesForEmptyPCM() {
    let recordedAudio = RecordedAudio(
      pcmData: Data(),
      sampleRate: 16_000,
      duration: 0
    )

    #expect(recordedAudio.floatSamples().isEmpty)
    #expect(recordedAudio.transcriptionSamples().isEmpty)
  }

  @Test func recordedAudioPadsShortTranscriptionSamples() {
    let samples: [Float] = [0.25, -0.25]
    let data = samples.withUnsafeBufferPointer { buffer in
      Data(buffer: buffer)
    }
    let recordedAudio = RecordedAudio(
      pcmData: data,
      sampleRate: 16_000,
      duration: 0.000125
    )

    let paddedSamples = recordedAudio.transcriptionSamples(minimumSampleCount: 4)

    #expect(paddedSamples == [0.25, -0.25, 0, 0])
  }

  @Test func recordedAudioDoesNotPadLongEnoughTranscriptionSamples() {
    let samples: [Float] = [0.25, -0.25, 0.1, -0.1]
    let data = samples.withUnsafeBufferPointer { buffer in
      Data(buffer: buffer)
    }
    let recordedAudio = RecordedAudio(
      pcmData: data,
      sampleRate: 16_000,
      duration: 0.00025
    )

    #expect(recordedAudio.transcriptionSamples(minimumSampleCount: 4) == samples)
  }

  @Test func fluidAudioErrorsDescribeEmptyAudioAndOutput() {
    #expect(FluidAudioTranscriptionError.emptyAudio.errorDescription == "No audio was captured.")
    #expect(FluidAudioTranscriptionError.emptyOutput.errorDescription == "FluidAudio returned an empty transcription.")
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
