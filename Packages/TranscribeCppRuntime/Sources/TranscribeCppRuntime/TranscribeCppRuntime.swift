import CTranscribe
import Foundation

public enum TranscribeCppRuntimeError: LocalizedError, Equatable {
  case emptyAudio
  case audioTooLong
  case nullHandle(String)
  case versionMismatch(expected: String, actual: String)
  case native(context: String, status: Int32, message: String)

  public var errorDescription: String? {
    switch self {
      case .emptyAudio:
        return "No audio was provided to transcribe.cpp."
      case .audioTooLong:
        return "The recording contains too many samples for transcribe.cpp."
      case .nullHandle(let context):
        return "transcribe.cpp returned an empty \(context) handle."
      case .versionMismatch(let expected, let actual):
        return "The transcribe.cpp runtime is \(actual), but Chirp requires \(expected)."
      case .native(let context, _, let message):
        return "transcribe.cpp \(context) failed: \(message)"
    }
  }
}

public struct NativeTranscript: Sendable, Equatable {
  public let text: String
  public let backend: String

  public init(text: String, backend: String) {
    self.text = text
    self.backend = backend
  }
}

/// Owns one transcribe.cpp model and session. Callers must serialize access;
/// Chirp does that by keeping this object inside an actor.
public final class TranscribeCppModel {
  public static let requiredVersion = "0.1.3"

  private let model: OpaquePointer
  private let session: OpaquePointer
  public let backend: String

  public init(modelPath: String) throws {
    let actualVersion = String(cString: transcribe_version())
    guard Self.baseVersion(actualVersion) == Self.requiredVersion else {
      throw TranscribeCppRuntimeError.versionMismatch(
        expected: Self.requiredVersion,
        actual: actualVersion
      )
    }

    try Self.check(transcribe_init_backends_default(), context: "backend initialization")

    var loadParameters = transcribe_model_load_params()
    transcribe_model_load_params_init(&loadParameters)
    loadParameters.backend = TRANSCRIBE_BACKEND_AUTO

    var loadedModel: OpaquePointer?
    try modelPath.withCString { path in
      try Self.check(
        transcribe_model_load_file(path, &loadParameters, &loadedModel),
        context: "model loading"
      )
    }
    guard let loadedModel else {
      throw TranscribeCppRuntimeError.nullHandle("model")
    }

    var sessionParameters = transcribe_session_params()
    transcribe_session_params_init(&sessionParameters)
    var createdSession: OpaquePointer?
    do {
      try Self.check(
        transcribe_session_init(loadedModel, &sessionParameters, &createdSession),
        context: "session creation"
      )
    } catch {
      transcribe_model_free(loadedModel)
      throw error
    }
    guard let createdSession else {
      transcribe_model_free(loadedModel)
      throw TranscribeCppRuntimeError.nullHandle("session")
    }

    model = loadedModel
    session = createdSession
    backend = String(cString: transcribe_model_backend(loadedModel))
  }

  deinit {
    transcribe_session_free(session)
    transcribe_model_free(model)
  }

  public func transcribe(samples: [Float], language: String? = "en") throws -> NativeTranscript {
    guard !samples.isEmpty else {
      throw TranscribeCppRuntimeError.emptyAudio
    }
    guard samples.count <= Int(Int32.max) else {
      throw TranscribeCppRuntimeError.audioTooLong
    }

    var runParameters = transcribe_run_params()
    transcribe_run_params_init(&runParameters)
    runParameters.timestamps = TRANSCRIBE_TIMESTAMPS_NONE

    let run: (UnsafePointer<CChar>?) throws -> Void = { languagePointer in
      runParameters.language = languagePointer
      try samples.withUnsafeBufferPointer { buffer in
        try Self.check(
          transcribe_run(self.session, buffer.baseAddress, Int32(buffer.count), &runParameters),
          context: "transcription"
        )
      }
    }

    if let language {
      try language.withCString(run)
    } else {
      try run(nil)
    }

    return NativeTranscript(
      text: String(cString: transcribe_full_text(session)),
      backend: backend
    )
  }

  public static var runtimeVersion: String {
    String(cString: transcribe_version())
  }

  private static func check(_ status: transcribe_status, context: String) throws {
    guard status != TRANSCRIBE_OK else {
      return
    }

    let rawStatus = Int32(bitPattern: status.rawValue)
    throw TranscribeCppRuntimeError.native(
      context: context,
      status: rawStatus,
      message: String(cString: transcribe_status_string(rawStatus))
    )
  }

  private static func baseVersion(_ version: String) -> String {
    String(version.prefix { $0 == "." || $0.isNumber })
  }
}
