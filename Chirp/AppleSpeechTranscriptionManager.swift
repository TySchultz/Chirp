//
//  AppleSpeechTranscriptionManager.swift
//  Chirp
//

import AVFAudio
import Foundation
import Speech

enum TranscriptionModelState {
  case unloaded
  case loading
  case loaded
  case failed
}

enum AppleSpeechTranscriptionError: LocalizedError, Equatable {
  case emptyAudio
  case emptyOutput
  case invalidAudio
  case modelUnavailable
  case localeUnavailable(String)
  case compatibleAudioFormatUnavailable
  case audioConversionFailed

  var errorDescription: String? {
    switch self {
      case .emptyAudio:
        return "No audio was captured."
      case .emptyOutput:
        return "Apple Speech returned an empty transcription."
      case .invalidAudio:
        return "The recorded audio could not be read."
      case .modelUnavailable:
        return "Apple SpeechTranscriber is unavailable on this Mac."
      case .localeUnavailable(let identifier):
        return "Apple Speech does not support the \(identifier) locale on this Mac."
      case .compatibleAudioFormatUnavailable:
        return "Apple Speech could not find a compatible audio format."
      case .audioConversionFailed:
        return "The recorded audio could not be converted for Apple Speech."
    }
  }
}

actor AppleSpeechTranscriber {
  private let requestedLocale: Locale
  private var preparedLocale: Locale?
  private var preparationTask: Task<Locale, Error>?

  init(locale: Locale = Locale(identifier: "en-US")) {
    requestedLocale = locale
  }

  func prepare() async throws {
    _ = try await prepareLocale()
  }

  func transcribe(recordedAudio: RecordedAudio) async throws -> String {
    let inputBuffer = try Self.makePCMBuffer(from: recordedAudio)
    let locale = try await prepareLocale()
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let modules: [any SpeechModule] = [transcriber]

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: modules,
      considering: inputBuffer.format
    ) else {
      throw AppleSpeechTranscriptionError.compatibleAudioFormatUnavailable
    }

    let analyzerInputBuffer = try Self.convert(inputBuffer, to: analyzerFormat)
    let analyzer = SpeechAnalyzer(
      modules: modules,
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
    )
    let inputSequence = AsyncStream<AnalyzerInput> { continuation in
      continuation.yield(AnalyzerInput(buffer: analyzerInputBuffer))
      continuation.finish()
    }

    async let transcription = Self.collectResults(from: transcriber)

    do {
      if let lastSample = try await analyzer.analyzeSequence(inputSequence) {
        try await analyzer.finalizeAndFinish(through: lastSample)
      } else {
        await analyzer.cancelAndFinishNow()
      }

      return try await Self.normalizedText(from: transcription)
    } catch {
      await analyzer.cancelAndFinishNow()
      throw error
    }
  }

  private func prepareLocale() async throws -> Locale {
    if let preparedLocale {
      return preparedLocale
    }

    if let preparationTask {
      return try await preparationTask.value
    }

    let requestedLocale = requestedLocale
    let task = Task(priority: .userInitiated) {
      try await Self.installAssets(for: requestedLocale)
    }
    preparationTask = task

    do {
      let locale = try await task.value
      preparedLocale = locale
      preparationTask = nil
      return locale
    } catch {
      preparationTask = nil
      throw error
    }
  }

  private static func installAssets(for requestedLocale: Locale) async throws -> Locale {
    guard SpeechTranscriber.isAvailable else {
      throw AppleSpeechTranscriptionError.modelUnavailable
    }

    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      throw AppleSpeechTranscriptionError.localeUnavailable(requestedLocale.identifier)
    }

    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let modules: [any SpeechModule] = [transcriber]
    guard await AssetInventory.status(forModules: modules) != .unsupported else {
      throw AppleSpeechTranscriptionError.modelUnavailable
    }

    if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: modules) {
      try await installationRequest.downloadAndInstall()
    }

    return locale
  }

  static func makePCMBuffer(from recordedAudio: RecordedAudio) throws -> AVAudioPCMBuffer {
    guard !recordedAudio.pcmData.isEmpty else {
      throw AppleSpeechTranscriptionError.emptyAudio
    }
    guard recordedAudio.sampleRate > 0,
          recordedAudio.pcmData.count.isMultiple(of: MemoryLayout<Float>.size),
          recordedAudio.sampleCount <= Int(AVAudioFrameCount.max),
          let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: recordedAudio.sampleRate,
            channels: 1,
            interleaved: false
          ),
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(recordedAudio.sampleCount)
          ),
          let channelData = buffer.floatChannelData?.pointee else {
      throw AppleSpeechTranscriptionError.invalidAudio
    }

    recordedAudio.pcmData.withUnsafeBytes { rawBuffer in
      guard let samples = rawBuffer.bindMemory(to: Float.self).baseAddress else {
        return
      }
      channelData.update(from: samples, count: recordedAudio.sampleCount)
    }
    buffer.frameLength = AVAudioFrameCount(recordedAudio.sampleCount)
    return buffer
  }

  private static func convert(
    _ inputBuffer: AVAudioPCMBuffer,
    to outputFormat: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    if inputBuffer.format == outputFormat {
      return inputBuffer
    }

    guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
      throw AppleSpeechTranscriptionError.audioConversionFailed
    }

    let sampleRateRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
    let outputCapacity = AVAudioFrameCount(
      (Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up)
    ) + 1
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: outputCapacity
    ) else {
      throw AppleSpeechTranscriptionError.audioConversionFailed
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
      if suppliedInput {
        inputStatus.pointee = .endOfStream
        return nil
      }

      suppliedInput = true
      inputStatus.pointee = .haveData
      return inputBuffer
    }

    guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
      throw conversionError ?? AppleSpeechTranscriptionError.audioConversionFailed
    }

    return outputBuffer
  }

  private static func collectResults(from transcriber: SpeechTranscriber) async throws -> String {
    var transcription = ""
    for try await result in transcriber.results {
      transcription.append(String(result.text.characters))
    }
    return transcription
  }

  static func normalizedText(from text: String) throws -> String {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw AppleSpeechTranscriptionError.emptyOutput
    }
    return trimmedText
  }
}

@MainActor
final class AppleSpeechTranscriptionManager: ObservableObject {
  @Published var isModelLoaded = false
  @Published var loadingProgress = "Initializing..."
  @Published var loadingProgressValue: Float = 0
  @Published var modelState: TranscriptionModelState = .unloaded

  private let transcriber: AppleSpeechTranscriber

  init(transcriber: AppleSpeechTranscriber = AppleSpeechTranscriber()) {
    self.transcriber = transcriber
  }

  func loadModel() {
    Task { [weak self] in
      do {
        try await self?.prepareModelForUse()
      } catch {
        print("Apple Speech setup failed: \(error.localizedDescription)")
      }
    }
  }

  func transcribe(recordedAudio: RecordedAudio) async throws -> String {
    try await prepareModelForUse()
    return try await transcriber.transcribe(recordedAudio: recordedAudio)
  }

  private func prepareModelForUse() async throws {
    guard modelState != .loaded else {
      return
    }

    loadingProgress = "Preparing Apple Speech model..."
    loadingProgressValue = 0.25
    modelState = .loading

    do {
      try await transcriber.prepare()
      isModelLoaded = true
      loadingProgress = "Apple Speech ready"
      loadingProgressValue = 1
      modelState = .loaded
    } catch {
      isModelLoaded = false
      loadingProgress = "Apple Speech setup failed: \(error.localizedDescription)"
      loadingProgressValue = 0
      modelState = .failed
      throw error
    }
  }
}
