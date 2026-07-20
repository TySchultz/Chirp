//
//  TranscribeCppParakeetTests.swift
//  ChirpTests
//

import Foundation
import Testing
@testable import Chirp

struct TranscribeCppParakeetTests {
  @Test func pinnedNativeRuntimeIsLinked() {
    #expect(TranscribeCppParakeetTranscriber.runtimeVersion == "0.1.3")
  }

  @Test func recordedAudioProducesFloatSamples() {
    let expected: [Float] = [0, 0.25, -0.5, 1]
    let audio = RecordedAudio(
      pcmData: expected.withUnsafeBufferPointer { Data(buffer: $0) },
      sampleRate: 16_000,
      duration: 0.25
    )

    #expect(audio.floatSamples() == expected)
  }

  @Test func shortAudioIsPaddedToOneSecondForParakeet() {
    let samples: [Float] = [0.25, -0.5]
    let audio = RecordedAudio(
      pcmData: samples.withUnsafeBufferPointer { Data(buffer: $0) },
      sampleRate: 16_000,
      duration: Double(samples.count) / 16_000
    )

    let padded = audio.parakeetSamples()

    #expect(padded.count == 16_000)
    #expect(Array(padded.prefix(2)) == samples)
    #expect(padded.dropFirst(2).allSatisfy { $0 == 0 })
  }

  @Test func emptyAudioIsNotPadded() {
    let audio = RecordedAudio(pcmData: Data(), sampleRate: 16_000, duration: 0)

    #expect(audio.parakeetSamples().isEmpty)
  }

  @Test func normalizedParakeetTextTrimsWhitespace() throws {
    #expect(
      try TranscribeCppParakeetTranscriber.normalizedText(from: "  Hello from Parakeet.\n")
        == "Hello from Parakeet."
    )
  }

  @Test func emptyParakeetOutputThrows() {
    #expect(throws: ParakeetTranscriptionError.emptyOutput) {
      try TranscribeCppParakeetTranscriber.normalizedText(from: " \n ")
    }
  }

  @Test func pinnedModelMetadataMatchesTheSelectedVariant() {
    let model = ParakeetModelDescriptor.current

    #expect(model.fileName == "parakeet-tdt-0.6b-v2-Q4_K_M.gguf")
    #expect(model.expectedByteCount == 475_491_840)
    #expect(model.expectedSHA256.count == 64)
    #expect(model.downloadURL.host == "huggingface.co")
  }

  @Test func modelValidationChecksSizeAndSHA256() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let modelURL = directory.appendingPathComponent("fixture.gguf")
    try Data("abc".utf8).write(to: modelURL)
    let fixture = ParakeetModelDescriptor(
      fileName: "fixture.gguf",
      downloadURL: URL(string: "https://example.com/fixture.gguf")!,
      expectedByteCount: 3,
      expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )

    #expect(try ParakeetModelStore.isValidModel(at: modelURL, descriptor: fixture))
  }
}
