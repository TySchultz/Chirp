//
//  AboutPage.swift
//  Chirp
//
import SwiftUI

struct AppHeader: View {
    let appVersion: String
    
    var body: some View {
        HStack {
            Image(nsImage: NSImage(named: NSImage.applicationIconName)!)
                .resizable()
                .frame(width: 128, height: 128)
            VStack(alignment: .leading) {
                Text("Chirp")
                    .font(.largeTitle)
                    .fontDesign(.serif)
                    .fontWeight(.bold)
                Text("\(appVersion)")
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CreatorInfo: View {
    var body: some View {
        HStack(alignment: .center) {
            Text("Open source on GitHub")
                .fontWeight(.medium)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(action: {
                if let url = URL(string: "https://github.com/TySchultz/Chirp") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text("GitHub")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(5)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
    }
}

struct OpenSourceLibrary: View {
    let name: String
    let description: String
    let url: String
    
    var body: some View {
        Button(action: {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(name)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.blue)
                }
                Text(description)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.thickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct AboutPage: View {
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                AppHeader(appVersion: appVersion)
                
                CreatorInfo()
                
                VStack(spacing: 8) {
                    Text("Open Source".uppercased())
                        .fontWeight(.medium)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    OpenSourceLibrary(
                        name: "Audio Kit",
                        description: "AudioKit is an audio synthesis, processing, and analysis platform for iOS, macOS (including Catalyst), and tvOS.",
                        url: "https://github.com/AudioKit/AudioKit"
                    )
                    
                    OpenSourceLibrary(
                        name: "FluidAudio",
                        description: "Local speech transcription on Apple devices using Core ML audio models.",
                        url: "https://github.com/FluidInference/FluidAudio"
                    )
                    
                    OpenSourceLibrary(
                        name: "KeyboardShortcuts",
                        description: "Add user-customizable global keyboard shortcuts to your macOS app in minutes.",
                        url: "https://github.com/sindresorhus/KeyboardShortcuts"
                    )
                }
            }
            .padding()
        }
    }
}

#Preview {
    AboutPage()
}
