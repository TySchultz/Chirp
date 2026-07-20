//
//  TranscribeCppParakeetTranscriptionManager.swift
//  Chirp
//

import CryptoKit
import Foundation
import TranscribeCppRuntime

struct ParakeetModelDescriptor: Sendable, Equatable {
  static let current = ParakeetModelDescriptor(
    fileName: "parakeet-tdt-0.6b-v2-Q4_K_M.gguf",
    downloadURL: URL(
      string: "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v2-gguf/resolve/main/parakeet-tdt-0.6b-v2-Q4_K_M.gguf"
    )!,
    expectedByteCount: 475_491_840,
    expectedSHA256: "4853f9653f641d376e6f7de65d73c7a34a73677704a606727bf51acc83f999f3"
  )

  let fileName: String
  let downloadURL: URL
  let expectedByteCount: Int64
  let expectedSHA256: String
}

struct ParakeetPreparationProgress: Sendable, Equatable {
  let fractionCompleted: Float
  let message: String
}

enum ParakeetTranscriptionError: LocalizedError, Equatable {
  case invalidDownloadResponse
  case unexpectedModelSize(expected: Int64, actual: Int64)
  case modelChecksumMismatch
  case emptyAudio
  case emptyOutput
  case invalidAudio
  case incompatibleAudioFormat(sampleRate: Double)
  case primaryAndFallbackFailed(parakeet: String, appleSpeech: String)

  var errorDescription: String? {
    switch self {
      case .invalidDownloadResponse:
        return "The Parakeet model server returned an invalid response."
      case .unexpectedModelSize(let expected, let actual):
        return "The Parakeet model download was incomplete (expected \(expected) bytes, received \(actual))."
      case .modelChecksumMismatch:
        return "The downloaded Parakeet model failed its integrity check."
      case .emptyAudio:
        return "No audio was captured."
      case .emptyOutput:
        return "Parakeet returned an empty transcription."
      case .invalidAudio:
        return "The recorded audio could not be read as Float32 samples."
      case .incompatibleAudioFormat(let sampleRate):
        return "Parakeet requires 16 kHz mono Float32 audio, but received \(sampleRate) Hz audio."
      case .primaryAndFallbackFailed(let parakeet, let appleSpeech):
        return "Parakeet failed (\(parakeet)) and Apple Speech fallback failed (\(appleSpeech))."
    }
  }
}

private final class ParakeetDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let progressHandler: @Sendable (ParakeetPreparationProgress) -> Void

  init(progressHandler: @escaping @Sendable (ParakeetPreparationProgress) -> Void) {
    self.progressHandler = progressHandler
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let expectedBytes = max(totalBytesExpectedToWrite, ParakeetModelDescriptor.current.expectedByteCount)
    let fraction = min(max(Float(totalBytesWritten) / Float(expectedBytes), 0), 1)
    let downloadedMegabytes = totalBytesWritten / 1_000_000
    let expectedMegabytes = expectedBytes / 1_000_000
    progressHandler(
      ParakeetPreparationProgress(
        fractionCompleted: fraction * 0.95,
        message: "Downloading Parakeet v2… \(downloadedMegabytes) of \(expectedMegabytes) MB"
      )
    )
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}

struct ParakeetModelStore: Sendable {
  let descriptor: ParakeetModelDescriptor
  let modelDirectoryURL: URL

  init(
    descriptor: ParakeetModelDescriptor = .current,
    modelDirectoryURL: URL? = nil
  ) throws {
    self.descriptor = descriptor
    if let modelDirectoryURL {
      self.modelDirectoryURL = modelDirectoryURL
    } else {
      self.modelDirectoryURL = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      .appendingPathComponent("Chirp", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
    }
  }

  var installedModelURL: URL {
    modelDirectoryURL.appendingPathComponent(descriptor.fileName, isDirectory: false)
  }

  func prepareModel(
    progressHandler: @escaping @Sendable (ParakeetPreparationProgress) -> Void
  ) async throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: modelDirectoryURL,
      withIntermediateDirectories: true
    )

    if fileManager.fileExists(atPath: installedModelURL.path) {
      progressHandler(
        ParakeetPreparationProgress(
          fractionCompleted: 0.96,
          message: "Verifying installed Parakeet v2 model…"
        )
      )
      if try Self.isValidModel(at: installedModelURL, descriptor: descriptor) {
        return installedModelURL
      }
      try fileManager.removeItem(at: installedModelURL)
    }

    progressHandler(
      ParakeetPreparationProgress(
        fractionCompleted: 0,
        message: "Downloading Parakeet v2…"
      )
    )
    let delegate = ParakeetDownloadProgressDelegate(progressHandler: progressHandler)
    let (temporaryURL, response) = try await URLSession.shared.download(
      from: descriptor.downloadURL,
      delegate: delegate
    )
    guard let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode) else {
      throw ParakeetTranscriptionError.invalidDownloadResponse
    }

    progressHandler(
      ParakeetPreparationProgress(
        fractionCompleted: 0.96,
        message: "Verifying downloaded Parakeet v2 model…"
      )
    )
    guard try Self.isValidModel(at: temporaryURL, descriptor: descriptor) else {
      let actualSize = try Self.fileSize(at: temporaryURL)
      guard actualSize == descriptor.expectedByteCount else {
        throw ParakeetTranscriptionError.unexpectedModelSize(
          expected: descriptor.expectedByteCount,
          actual: actualSize
        )
      }
      throw ParakeetTranscriptionError.modelChecksumMismatch
    }

    let stagedURL = modelDirectoryURL.appendingPathComponent(
      "\(descriptor.fileName).download",
      isDirectory: false
    )
    if fileManager.fileExists(atPath: stagedURL.path) {
      try fileManager.removeItem(at: stagedURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: stagedURL)
    if fileManager.fileExists(atPath: installedModelURL.path) {
      _ = try fileManager.replaceItemAt(installedModelURL, withItemAt: stagedURL)
    } else {
      try fileManager.moveItem(at: stagedURL, to: installedModelURL)
    }
    return installedModelURL
  }

  static func isValidModel(
    at url: URL,
    descriptor: ParakeetModelDescriptor = .current
  ) throws -> Bool {
    guard try fileSize(at: url) == descriptor.expectedByteCount else {
      return false
    }
    return try sha256(at: url) == descriptor.expectedSHA256
  }

  private static func fileSize(at url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values.fileSize ?? 0)
  }

  private static func sha256(at url: URL) throws -> String {
    let fileHandle = try FileHandle(forReadingFrom: url)
    defer { try? fileHandle.close() }

    var hasher = SHA256()
    while let data = try fileHandle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

actor TranscribeCppParakeetTranscriber {
  private let modelStore: ParakeetModelStore
  private var model: TranscribeCppModel?
  private var preparationTask: Task<TranscribeCppModel, Error>?

  init(modelStore: ParakeetModelStore? = nil) {
    if let modelStore {
      self.modelStore = modelStore
    } else {
      self.modelStore = try! ParakeetModelStore()
    }
  }

  nonisolated static var runtimeVersion: String {
    TranscribeCppModel.runtimeVersion
  }

  func prepare(
    progressHandler: @escaping @Sendable (ParakeetPreparationProgress) -> Void
  ) async throws {
    if model != nil {
      return
    }
    if let preparationTask {
      model = try await preparationTask.value
      return
    }

    let modelStore = modelStore
    let task = Task(priority: .userInitiated) {
      let modelURL = try await modelStore.prepareModel(progressHandler: progressHandler)
      progressHandler(
        ParakeetPreparationProgress(
          fractionCompleted: 0.98,
          message: "Loading Parakeet v2 with transcribe.cpp…"
        )
      )
      return try TranscribeCppModel(modelPath: modelURL.path)
    }
    preparationTask = task

    do {
      model = try await task.value
      preparationTask = nil
    } catch {
      preparationTask = nil
      throw error
    }
  }

  func unload() {
    preparationTask?.cancel()
    preparationTask = nil
    model = nil
  }

  func transcribe(recordedAudio: RecordedAudio) throws -> String {
    guard recordedAudio.sampleRate == 16_000 else {
      throw ParakeetTranscriptionError.incompatibleAudioFormat(
        sampleRate: recordedAudio.sampleRate
      )
    }
    guard recordedAudio.pcmData.count.isMultiple(of: MemoryLayout<Float>.size) else {
      throw ParakeetTranscriptionError.invalidAudio
    }
    guard let model else {
      throw TranscribeCppRuntimeError.nullHandle("prepared model")
    }

    let samples = recordedAudio.parakeetSamples()
    guard !samples.isEmpty else {
      throw ParakeetTranscriptionError.emptyAudio
    }
    let transcript = try model.transcribe(samples: samples, language: "en")
    return try Self.normalizedText(from: transcript.text)
  }

  static func normalizedText(from text: String) throws -> String {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw ParakeetTranscriptionError.emptyOutput
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

  func parakeetSamples(minimumSampleCount: Int = 16_000) -> [Float] {
    var samples = floatSamples()
    guard !samples.isEmpty, samples.count < minimumSampleCount else {
      return samples
    }
    samples.append(contentsOf: repeatElement(0, count: minimumSampleCount - samples.count))
    return samples
  }
}

@MainActor
final class TranscriptionManager: ObservableObject {
  @Published var isModelLoaded = false
  @Published var loadingProgress = "Initializing…"
  @Published var loadingProgressValue: Float = 0
  @Published var modelState: TranscriptionModelState = .unloaded

  private let parakeetTranscriber: TranscribeCppParakeetTranscriber
  private let appleSpeechTranscriber: AppleSpeechTranscriber
  private var idleUnloadTask: Task<Void, Never>?

  init(
    parakeetTranscriber: TranscribeCppParakeetTranscriber = TranscribeCppParakeetTranscriber(),
    appleSpeechTranscriber: AppleSpeechTranscriber = AppleSpeechTranscriber()
  ) {
    self.parakeetTranscriber = parakeetTranscriber
    self.appleSpeechTranscriber = appleSpeechTranscriber
  }

  deinit {
    idleUnloadTask?.cancel()
  }

  func loadModel() {
    Task { [weak self] in
      do {
        try await self?.prepareModelForUse()
      } catch {
        print("Parakeet setup failed; Apple Speech remains available: \(error.localizedDescription)")
      }
    }
  }

  func transcribe(recordedAudio: RecordedAudio) async throws -> String {
    cancelIdleUnload()
    do {
      try await prepareModelForUse()
      let transcription = try await parakeetTranscriber.transcribe(
        recordedAudio: recordedAudio
      )
      scheduleIdleUnload()
      return transcription
    } catch {
      let parakeetMessage = error.localizedDescription
      await parakeetTranscriber.unload()
      markParakeetFailure(error)
      do {
        return try await appleSpeechTranscriber.transcribe(recordedAudio: recordedAudio)
      } catch {
        throw ParakeetTranscriptionError.primaryAndFallbackFailed(
          parakeet: parakeetMessage,
          appleSpeech: error.localizedDescription
        )
      }
    }
  }

  private func prepareModelForUse() async throws {
    cancelIdleUnload()
    guard modelState != .loaded else {
      return
    }

    isModelLoaded = false
    loadingProgress = "Preparing Parakeet v2…"
    loadingProgressValue = 0
    modelState = .loading

    do {
      try await parakeetTranscriber.prepare { [weak self] progress in
        Task { @MainActor [weak self] in
          self?.loadingProgress = progress.message
          self?.loadingProgressValue = progress.fractionCompleted
        }
      }
      isModelLoaded = true
      loadingProgress = "Parakeet v2 ready with transcribe.cpp"
      loadingProgressValue = 1
      modelState = .loaded
    } catch {
      markParakeetFailure(error)
      throw error
    }
  }

  private func markParakeetFailure(_ error: Error) {
    isModelLoaded = false
    loadingProgress = "Parakeet unavailable; using Apple Speech: \(error.localizedDescription)"
    loadingProgressValue = 0
    modelState = .failed
  }

  private func cancelIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
  }

  private func scheduleIdleUnload() {
    cancelIdleUnload()
    idleUnloadTask = Task { [weak self, parakeetTranscriber] in
      do {
        try await Task.sleep(for: .seconds(30 * 60))
      } catch {
        return
      }
      await parakeetTranscriber.unload()
      guard !Task.isCancelled else {
        return
      }
      self?.modelDidUnloadAfterIdleTimeout()
    }
  }

  private func modelDidUnloadAfterIdleTimeout() {
    isModelLoaded = false
    loadingProgress = "Parakeet v2 ready on demand"
    loadingProgressValue = 0
    modelState = .unloaded
    idleUnloadTask = nil
  }
}
