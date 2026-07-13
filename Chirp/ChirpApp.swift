//
//  ChirpApp.swift
//  Chirp
//
//

import SwiftUI

enum ChirpWindows: Int, Hashable, Identifiable {
  var id: Int {
    return self.rawValue
  }
  case chirp = 0
  case about = 1
  case howItWorks = 2
//  case privacy = 3
  case chirps = 4
}

@main
struct ChirpApp: App {
  @StateObject private var transcriptionManager: AppleSpeechTranscriptionManager
  @StateObject private var recordingSession: RecordingSessionController
  
  @State var chirpWindow: ChirpWindows = .chirp

  init() {
    let transcriptionManager = AppleSpeechTranscriptionManager()
    _transcriptionManager = StateObject(wrappedValue: transcriptionManager)
    _recordingSession = StateObject(wrappedValue: RecordingSessionController(transcriptionManager: transcriptionManager))
    transcriptionManager.loadModel()
  }

  var body: some Scene {
    WindowGroup {
      NavigationSplitView {
        List(selection: $chirpWindow) {
          Group {
            NavigationLink(value: ChirpWindows.chirp) {
              HStack {
                Image(systemName: "gear")
                  .font(.title2)
                  .foregroundStyle(.white)
                  .padding(4)
                  .frame(width: 32, height: 32)
                  .background(.green)
                  .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
                Text("General")
                  .frame(maxWidth:.infinity, alignment: .leading)
              }
            }
            
            
            NavigationLink(value: ChirpWindows.chirps) {
              HStack {
                Image(systemName: "bird.fill")
                  .font(.title2)
                  .foregroundStyle(.white)
                  .padding(4)
                  .frame(width: 32, height: 32)
                  .background(.red)
                  .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
                Text("Recent Chirps")
                  .frame(maxWidth:.infinity, alignment: .leading)
              }
            }
          
//            NavigationLink(value: ChirpWindows.privacy) {
//              HStack {
//                Image(systemName: "shield.fill")
//                  .font(.title2)
//                  .foregroundStyle(.white)
//                  .padding(4)
//                  .frame(width: 32, height: 32)
//                  .background(.blue)
//                  .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
//                Text("Privacy")
//                  .frame(maxWidth:.infinity, alignment: .leading)
//              }
//            }
            
            NavigationLink(value: ChirpWindows.about) {
              HStack {
                Image(systemName: "info.circle")
                  .font(.title2)
                  .foregroundStyle(.white)
                  .padding(4)
                  .frame(width: 32, height: 32)
                  .background(.gray)
                  .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
                Text("About")
                  .frame(maxWidth:.infinity, alignment: .leading)
              }
            }
          }
        }
        .frame(width: 225)
      } detail: {
        switch chirpWindow {
          case .chirp:
            ContentView(
              recordingSession: recordingSession
            )
            .padding()
       
          case .about:
            AboutPage()
              .padding()
          case .howItWorks:
            HowItWorksView()
              .padding()
          case .chirps:
            ChirpListView(recentTranscriptions: $recordingSession.recentTranscriptions)
        }
      }
      .environmentObject(transcriptionManager)
      .frame(minWidth: 600) // Also set a fixed size for the About view
    }
    .windowResizability(.contentSize)
  }
}

class FloatingPanel: NSPanel {
  init(contentRect: NSRect, backing: NSWindow.BackingStoreType, defer flag: Bool) {
    super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: backing, defer: flag)
    
    self.isFloatingPanel = true
    self.level = .statusBar
    
    // Keep the panel visible as the user moves between Spaces and fullscreen apps.
    self.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .ignoresCycle,
      .stationary
    ]
    self.hidesOnDeactivate = false
    self.ignoresMouseEvents = true
    self.isReleasedWhenClosed = false
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
  }
  
  override var canBecomeKey: Bool {
    return false
  }
  
  override var canBecomeMain: Bool {
    return false
  }
}
