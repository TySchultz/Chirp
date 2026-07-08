//
//  FluidAudioTranscriptionManager.swift
//  Chirp
//
//

import FluidAudio
import Foundation

enum LocalTranscriptionModelState {
  case unloaded
  case loading
  case loaded
  case failed
}

enum FluidAudioTranscriptionError: LocalizedError, Equatable {
  case emptyAudio
  case emptyOutput

  var errorDescription: String? {
    switch self {
      case .emptyAudio:
        return "No audio was captured."
      case .emptyOutput:
        return "FluidAudio returned an empty transcription."
    }
  }
}

actor FluidAudioTranscriber {
  private var asrManager: AsrManager?
  private var asrModels: AsrModels?
  private var preparationTask: Task<Void, Error>?

  func prepare() async throws {
    if asrManager != nil {
      return
    }

    if let preparationTask {
      return try await preparationTask.value
    }

    let task = Task(priority: .userInitiated) { [weak self] in
      let models = try await AsrModels.downloadAndLoad(version: .v2)
      let manager = AsrManager(config: .default, models: models)

      await self?.store(manager: manager, models: models)
    }

    preparationTask = task
    do {
      try await task.value
      preparationTask = nil
    } catch {
      preparationTask = nil
      throw error
    }
  }

  func unload() async {
    preparationTask?.cancel()
    preparationTask = nil
    await asrManager?.cleanup()
    asrManager = nil
    asrModels = nil
  }

  func transcribe(recordedAudio: RecordedAudio) async throws -> String {
    let samples = recordedAudio.transcriptionSamples()
    guard !samples.isEmpty else {
      throw FluidAudioTranscriptionError.emptyAudio
    }

    try await prepare()
    guard let asrManager else {
      throw FluidAudioTranscriptionError.emptyOutput
    }

    var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
    let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
    return try Self.normalizedText(from: result.text)
  }

  func transcribe(audioURL: URL) async throws -> String {
    try await prepare()
    guard let asrManager else {
      throw FluidAudioTranscriptionError.emptyOutput
    }

    var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
    let result = try await asrManager.transcribe(audioURL, decoderState: &decoderState)
    return try Self.normalizedText(from: result.text)
  }

  private func store(manager: AsrManager, models: AsrModels) {
    asrManager = manager
    asrModels = models
  }

  private static func normalizedText(from text: String) throws -> String {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw FluidAudioTranscriptionError.emptyOutput
    }

    return trimmedText
  }
}

extension RecordedAudio {
  func floatSamples() -> [Float] {
    pcmData.withUnsafeBytes { rawBuffer in
      Array(rawBuffer.bindMemory(to: Float.self))
    }
  }

  func transcriptionSamples(minimumSampleCount: Int = 16_000) -> [Float] {
    var samples = floatSamples()
    guard !samples.isEmpty, samples.count < minimumSampleCount else {
      return samples
    }

    samples.append(contentsOf: repeatElement(0, count: minimumSampleCount - samples.count))
    return samples
  }
}

@MainActor
class FluidAudioTranscriptionManager: ObservableObject {
  @Published var isModelLoaded = false
  @Published var loadingProgress = "Initializing..."
  @Published var loadingProgressValue: Float = 0.0
  @Published var modelState: LocalTranscriptionModelState = .unloaded

  private let transcriber: FluidAudioTranscriber
  private var idleUnloadTask: Task<Void, Never>?

  init(transcriber: FluidAudioTranscriber = FluidAudioTranscriber()) {
    self.transcriber = transcriber
  }

  func loadModel() {
    Task { [weak self] in
      do {
        try await self?.prepareModelForUse()
      } catch {
        print("FluidAudio setup failed: \(error.localizedDescription)")
      }
    }
  }

  func transcribe(audioURL: URL) async throws -> String {
    try await prepareModelForUse()
    do {
      let transcription = try await transcriber.transcribe(audioURL: audioURL)
      scheduleIdleUnload()
      return transcription
    } catch {
      scheduleIdleUnload()
      throw error
    }
  }

  func transcribe(recordedAudio: RecordedAudio) async throws -> String {
    try await prepareModelForUse()
    do {
      let transcription = try await transcriber.transcribe(recordedAudio: recordedAudio)
      scheduleIdleUnload()
      return transcription
    } catch {
      scheduleIdleUnload()
      throw error
    }
  }

  deinit {
    idleUnloadTask?.cancel()
  }

  private func cancelIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
  }

  private func prepareModelForUse() async throws {
    cancelIdleUnload()
    guard modelState != .loaded else {
      return
    }

    loadingProgress = "Preparing FluidAudio v2..."
    loadingProgressValue = 0.25
    modelState = .loading

    do {
      try await transcriber.prepare()
      isModelLoaded = true
      loadingProgress = "FluidAudio v2 ready"
      loadingProgressValue = 1.0
      modelState = .loaded
    } catch {
      isModelLoaded = false
      loadingProgress = "FluidAudio setup failed: \(error.localizedDescription)"
      loadingProgressValue = 0.0
      modelState = .failed
      throw error
    }
  }

  private func scheduleIdleUnload() {
    cancelIdleUnload()
    idleUnloadTask = Task { [weak self, transcriber] in
      do {
        try await Task.sleep(nanoseconds: Self.modelIdleUnloadNanoseconds)
      } catch {
        return
      }

      await transcriber.unload()
      guard !Task.isCancelled else {
        return
      }
      self?.modelDidUnloadAfterIdleTimeout()
    }
  }

  private func modelDidUnloadAfterIdleTimeout() {
    isModelLoaded = false
    loadingProgress = "FluidAudio v2 unloaded after idle"
    loadingProgressValue = 0.0
    modelState = .unloaded
    idleUnloadTask = nil
  }

  nonisolated private static let modelIdleUnloadNanoseconds: UInt64 = 30 * 60 * 1_000_000_000
}
