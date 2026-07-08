//
//  ChirpListView.swift
//  Chirp
//
//

import SwiftUI


struct ChirpListView: View {
  @Binding var recentTranscriptions: [TranscriptionOutput]
  @State private var copiedTranscriptionId: UUID?
  
  var body: some View {
    List {
      VStack(alignment: .leading,spacing: 8) {
        Text("Recent Chirps")
          .font(.title3)
          .fontWeight(.medium)
        Text("Intentionally, chirp only keeps track of your previous 10 chirps.")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding()
      .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
      
      ForEach(recentTranscriptions.reversed()) { transcription in
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8){
            Text(transcription.transcription.trimmingCharacters(in: .whitespacesAndNewlines))
              .font(.body)
              .fontWeight(.medium)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
            Text(transcription.output.trimmingCharacters(in: .whitespacesAndNewlines))
              .font(.subheadline)
              .fontWeight(.regular)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          HStack(spacing: 16) {
            Text(formatDate(transcription.timestamp))
              .font(.caption)
              .foregroundColor(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
            
            if copiedTranscriptionId == transcription.id {
              Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            } else {
              Image(systemName: "doc.text")
                .onTapGesture {
                  copyToClipboard(transcription.output)
                  copiedTranscriptionId = transcription.id
                }
            }
            
            Image(systemName: "trash")
              .onTapGesture {
                deleteTranscription(transcription)
              }
          }
        }
        .padding()
      }
    }
    .background(
      ContentUnavailableView(
        "Empty",
        systemImage: "microphone.circle.fill",
        description: Text("You haven't transcribed any chirps yet.")
      )
      .opacity(recentTranscriptions.isEmpty ? 1.0 : 0.0)
    )
  }
  
  private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  
  private func deleteTranscription(_ transcription: TranscriptionOutput) {
    if let index = recentTranscriptions.firstIndex(where: { $0.id == transcription.id }) {
      recentTranscriptions.remove(at: index)
    }
  }
  
  private func formatDate(_ date: Date) -> String {
    Self.dateFormatter.string(from: date)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()
}

#Preview {
  ChirpListView(recentTranscriptions: .constant([]))
}
