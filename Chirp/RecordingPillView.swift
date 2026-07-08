//
//  RecordingPillView.swift
//  Chirp
//
//

import SwiftUI

struct RecordingPillView: View {
  // MARK: - Bindings & State
  @ObservedObject var recordingSession: RecordingSessionController
  let dismissPanel: () -> Void
  
  @State private var dismissToken = UUID()
  @State private var isResultVisible = false
  @State private var isVisible = false
  @State private var isProcessingIconPulsing = false
  
  private let resultDisplayDelay: TimeInterval = 1.4
  private let resultFadeDuration: TimeInterval = 0.34
  private let stateSpring = Animation.interpolatingSpring(stiffness: 320, damping: 20)
  
  // MARK: - Body
  var body: some View {
    ZStack {
      glassBackground
      content
    }
    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .center)
    .opacity(isVisible ? 1 : 0)
    .onAppear {
      isVisible = true
    }
    .onChange(of: recordingSession.isPreparingRecording) { _, newValue in
      if newValue {
        resetRecordingStartState()
        isVisible = true
      } else {
        scheduleIdleDismissIfNeeded()
      }
    }
    .onChange(of: recordingSession.isRecording) { _, newValue in
      if newValue {
        resetRecordingStartState()
        isVisible = true
      } else {
        scheduleIdleDismissIfNeeded()
      }
    }
    .onChange(of: recordingSession.isProcessing) { _, newValue in
      if newValue {
        dismissToken = UUID()
        isResultVisible = false
        isProcessingIconPulsing = true
        isVisible = true
      } else {
        isProcessingIconPulsing = false
        scheduleIdleDismissIfNeeded()
      }
    }
    .onChange(of: recordingSession.latestChirp) { _, newValue in
      scheduleDismiss(for: newValue)
    }
  }
  
  // MARK: - Subviews
  
  private var glassBackground: some View {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
      .fill(backgroundColor)
      .background {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(.thinMaterial)
      }
      .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
  }
  
  @ViewBuilder
  private var content: some View {
    if recordingSession.isPreparingRecording {
      Color.clear
        .frame(maxWidth: .infinity, alignment: .center)
        .transition(stateTransition)
    } else if recordingSession.isRecording {
      WaveformView(levels: recordingSession.recordingAudioLevels)
        .foregroundStyle(.primary.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 18)
    } else if recordingSession.isProcessing {
      Image(systemName: "brain.head.profile")
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(.primary.opacity(0.92))
        .scaleEffect(isProcessingIconPulsing ? 1.08 : 0.94)
        .opacity(isProcessingIconPulsing ? 1 : 0.72)
        .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true), value: isProcessingIconPulsing)
        .frame(maxWidth: .infinity, alignment: .center)
        .transition(stateTransition)
    } else if !recordingSession.latestChirp.isEmpty {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(.primary.opacity(0.92))
        .opacity(isResultVisible ? 1 : 0)
        .scaleEffect(isResultVisible ? 1 : 0.75)
        .frame(maxWidth: .infinity, alignment: .center)
        .transition(stateTransition)
    } else {
      Color.clear
    }
  }

  private var stateTransition: AnyTransition {
    .scale(scale: 0.62)
      .combined(with: .opacity)
      .animation(stateSpring)
  }

  private var backgroundColor: Color {
    Color(nsColor: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white)
      .opacity(0.24)
  }

  private func resetRecordingStartState() {
    dismissToken = UUID()
    isResultVisible = false
    isProcessingIconPulsing = false
  }

  // MARK: - Dismissal
  
  private func scheduleDismiss(for text: String) {
    guard !text.isEmpty else { return }
    
    let token = UUID()
    dismissToken = token
    
    withAnimation(stateSpring) {
      isResultVisible = true
    }
    
    DispatchQueue.main.asyncAfter(deadline: .now() + resultDisplayDelay) {
      guard dismissToken == token,
            recordingSession.latestChirp == text else {
        return
      }
      
      isResultVisible = false
      isVisible = false
      
      DispatchQueue.main.asyncAfter(deadline: .now() + resultFadeDuration) {
        dismissView(for: text, token: token)
      }
    }
  }
  
  private func dismissView(for text: String, token: UUID) {
    guard !recordingSession.isPreparingRecording,
          !recordingSession.isRecording,
          !recordingSession.isProcessing,
          dismissToken == token,
          recordingSession.latestChirp == text else {
      return
    }
    
    dismissPanel()
  }

  private func scheduleIdleDismissIfNeeded() {
    guard !recordingSession.isPreparingRecording,
          !recordingSession.isRecording,
          !recordingSession.isProcessing,
          recordingSession.latestChirp.isEmpty else {
      return
    }

    let token = UUID()
    dismissToken = token

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      guard dismissToken == token,
            !recordingSession.isPreparingRecording,
            !recordingSession.isRecording,
            !recordingSession.isProcessing,
            recordingSession.latestChirp.isEmpty else {
        return
      }

      isVisible = false

      DispatchQueue.main.asyncAfter(deadline: .now() + resultFadeDuration) {
        guard dismissToken == token,
              !recordingSession.isPreparingRecording,
              !recordingSession.isRecording,
              !recordingSession.isProcessing,
              recordingSession.latestChirp.isEmpty else {
          return
        }

        dismissPanel()
      }
    }
  }
}
