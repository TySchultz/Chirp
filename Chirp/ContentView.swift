//
//  ContentView.swift
//  Squeek
//
//
import SwiftUI
import ApplicationServices
import Foundation
import Cocoa

import KeyboardShortcuts

// Add this extension at the top of your file
extension KeyboardShortcuts.Name {
    static let startRecording = Self("startRecording")
}

// Add this struct at the top of the file, outside of ContentView
struct TranscriptionOutput: Identifiable, Equatable {
    let id = UUID()
    let transcription: String
    let output: String
    let timestamp: Date
}

enum RecordingShortcutMode: String, CaseIterable, Identifiable {
  case toggle
  case pressAndHold

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .toggle:
        return "Press to start, press to stop"
      case .pressAndHold:
        return "Press and hold"
    }
  }

  var description: String {
    switch self {
      case .toggle:
        return "Press the shortcut once to start recording, then press it again to stop."
      case .pressAndHold:
        return "Hold the shortcut while speaking, then release it to stop recording."
    }
  }
}

struct ContentView: View {
  @EnvironmentObject private var transcriptionManager: FluidAudioTranscriptionManager
  @ObservedObject var recordingSession: RecordingSessionController
  @Environment(\.openWindow) var openWindow
  
  @MainActor @State var loaded: Bool = false
  @State var currentThread: Thread?
  @State private var accessibilityTrusted = AXIsProcessTrusted()

  @AppStorage("totalWordsTranscribedIn") private var totalWordsTranscribedIn = 0
  @AppStorage("totalWordsTranscribedOut") private var totalWordsTranscribedOut = 0
  @AppStorage("totalAudioSeconds") private var totalAudioSeconds = 0.0
  @AppStorage("totalTranscriptions") private var totalTranscriptions = 0
  @AppStorage("recordingShortcutMode") private var recordingShortcutMode = RecordingShortcutMode.toggle.rawValue
  @AppStorage("automaticallyPasteTranscript") private var automaticallyPasteTranscript = true
  @AppStorage("boostMicrophoneInput") private var boostMicrophoneInput = false
  @AppStorage("recordingInputDeviceUID") private var recordingInputDeviceUID = AudioInputDevice.automaticSelectionID

  private var shortcutMode: RecordingShortcutMode {
    RecordingShortcutMode(rawValue: recordingShortcutMode) ?? .toggle
  }
  
  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        
        Image("chirpheader")
          .resizable()
          .aspectRatio(1.77, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
          .frame(maxWidth: 1000)
          .overlay(alignment: .bottom) {
            if shouldShowSetupStatus {
              VStack(spacing: 8) {
                HStack(spacing: 8) {
                  Image(systemName: setupStatusIcon)
                  Text(setupStatusTitle)
                    .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                  ProgressView(value: transcriptionManager.loadingProgressValue, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(maxWidth: .infinity)
                  Text(String(format: "%.1f%%", transcriptionManager.loadingProgressValue * 100))
                    .font(.caption)
                    .foregroundColor(.gray)
                }
                Text(transcriptionManager.loadingProgress)
                  .font(.caption)
                  .foregroundColor(.gray)
              }
              .padding()
              .background(.ultraThinMaterial)
              .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
              .padding(.bottom)
            }
          }
        VStack(alignment: .leading,spacing: 8) {
          Text("Chirp: High-Quality, Private Transcription for Mac.")
            .fontWeight(.medium)
            .font(.title3)
          Text("I built Chirp to give you top-notch transcription without compromising privacy. It's 100% local - no data ever leaves your Mac. Quality meets security, right at your fingertips.")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
        
        
        HStack {
          VStack(alignment: .leading, spacing: 8) {
            Text("\(totalTranscriptions)")
              .font(.title)
              .fontWeight(.bold)
            Text("Total transcriptions")
              .foregroundStyle(.primary.opacity(0.8))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding()
          .background(.thickMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
          
          VStack(alignment: .leading, spacing: 8) {
            Text("\(totalWordsTranscribedIn)")
              .font(.title)
              .fontWeight(.bold)
            Text("Words transcribed (in)")
              .foregroundStyle(.primary.opacity(0.8))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding()
          .background(.thickMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
          
          VStack(alignment: .leading, spacing: 8) {
            Text("\(String(format: "%.2f", totalAudioSeconds))")
              .font(.title)
              .fontWeight(.bold)
            Text("Total duration (s)")
              .foregroundStyle(.primary.opacity(0.8))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding()
          .background(.thickMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
        }
        
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 8){
            Text("Keyboard Shortcut:")
              .fontWeight(.medium)
              .font(.title3)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(shortcutMode.description)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          KeyboardShortcuts.Recorder("", name: .startRecording)
        }
        .padding()
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))

        VStack(alignment: .leading, spacing: 12) {
          Text("Recording Shortcut Behavior:")
            .fontWeight(.medium)
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
          Picker("Recording Shortcut Behavior", selection: $recordingShortcutMode) {
            ForEach(RecordingShortcutMode.allCases) { mode in
              Text(mode.title).tag(mode.rawValue)
            }
          }
          .pickerStyle(.segmented)
          Text(shortcutMode.description)
            .foregroundStyle(.primary.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
        
        VStack(alignment: .leading, spacing: 12) {
          Text("Recording Input")
            .fontWeight(.medium)
            .font(.title3)
          Picker("Recording Input", selection: $recordingInputDeviceUID) {
            Text("Auto (system default)").tag(AudioInputDevice.automaticSelectionID)
            ForEach(recordingSession.inputDevices) { device in
              Text(device.displayName).tag(device.uid)
            }
          }
          .pickerStyle(.menu)
          Text(recordingInputDescription)
            .foregroundStyle(.primary.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))

        VStack(alignment: .leading, spacing: 12) {
          Toggle("Automatically paste transcript", isOn: $automaticallyPasteTranscript)
            .fontWeight(.medium)
            .font(.title3)
          Text("Copy every transcript to the clipboard, then paste it into the active text field when processing finishes.")
            .foregroundStyle(.primary.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
          if automaticallyPasteTranscript {
            accessibilityPermissionView
          }
        }
        .padding()
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))

        VStack(alignment: .leading, spacing: 12) {
          Toggle("Boost microphone input", isOn: $boostMicrophoneInput)
            .fontWeight(.medium)
            .font(.title3)
          Text("Temporarily raises the selected input device gain while recording, then restores it when recording stops. Bluetooth inputs are skipped.")
            .foregroundStyle(.primary.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
      }
    }
    .scrollIndicators(.hidden)
    .navigationTitle("Chirp")
    .onAppear {
      recordingSession.refreshInputDevices()
      refreshAccessibilityStatus()
      resetUnavailableInputSelectionIfNeeded()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshAccessibilityStatus()
    }
    .onChange(of: recordingSession.inputDevices) { _, _ in
      resetUnavailableInputSelectionIfNeeded()
    }
  }

  @ViewBuilder
  private var accessibilityPermissionView: some View {
    if accessibilityTrusted {
      Label("Auto-paste permission enabled", systemImage: "checkmark.circle.fill")
        .font(.callout.weight(.medium))
        .foregroundStyle(.green)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Label("Auto-paste needs Accessibility permission to press Cmd-V for you.", systemImage: "exclamationmark.triangle.fill")
          .font(.callout.weight(.medium))
          .foregroundStyle(.orange)
        HStack {
          Button("Open Accessibility Settings") {
            requestAccessibilityPermission()
            openAccessibilitySettings()
          }
          Button("Check Again") {
            refreshAccessibilityStatus()
          }
        }
      }
    }
  }

  private var recordingInputDescription: String {
    guard !recordingSession.inputDevices.isEmpty else {
      return "No input devices are currently available."
    }

    if recordingInputDeviceUID == AudioInputDevice.automaticSelectionID {
      if let defaultDevice = recordingSession.inputDevices.first(where: \.isDefault) {
        return "Auto records from \(defaultDevice.name), the current macOS input, so recording can start without switching devices."
      }

      return "Auto records from the current macOS input so recording can start without switching devices."
    }

    guard let resolvedDevice = AudioInputDevice.resolvedDevice(for: recordingInputDeviceUID, in: recordingSession.inputDevices) else {
      return "Chirp will use the system default input."
    }

    if !recordingSession.inputDevices.contains(where: { $0.uid == recordingInputDeviceUID }) {
      return "\(resolvedDevice.name) is being used because the selected input is unavailable."
    }

    return "Chirp will record from \(resolvedDevice.name)."
  }

  private var setupStatusTitle: String {
    switch transcriptionManager.modelState {
      case .failed:
        return "FluidAudio setup failed"
      case .loaded:
        return "FluidAudio ready"
      case .loading:
        return "Preparing FluidAudio..."
      case .unloaded:
        return "FluidAudio ready on demand"
    }
  }

  private var setupStatusIcon: String {
    switch transcriptionManager.modelState {
      case .failed:
        return "exclamationmark.triangle.fill"
      case .loaded:
        return "checkmark.circle.fill"
      case .loading:
        return "gearshape.fill"
      case .unloaded:
        return "pause.circle.fill"
    }
  }

  private var shouldShowSetupStatus: Bool {
    switch transcriptionManager.modelState {
      case .loading, .failed:
        return true
      case .loaded, .unloaded:
        return false
    }
  }
  
  private func resetUnavailableInputSelectionIfNeeded() {
    guard recordingInputDeviceUID != AudioInputDevice.automaticSelectionID,
          !recordingSession.inputDevices.contains(where: { $0.uid == recordingInputDeviceUID }) else {
      return
    }

    recordingInputDeviceUID = AudioInputDevice.automaticSelectionID
  }

  private func refreshAccessibilityStatus() {
    accessibilityTrusted = AXIsProcessTrusted()
  }

  private func requestAccessibilityPermission() {
    let options = [
      kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ] as CFDictionary
    accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
  }

  private func openAccessibilitySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
      return
    }

    NSWorkspace.shared.open(url)
  }
}
