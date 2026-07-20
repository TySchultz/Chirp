//
//  HowItWorksView.swift
//  Chirp
//
//

import SwiftUI

struct HowItWorksView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        
        Image("HowItWorks")
          .resizable()
          .aspectRatio(1.77, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
          .frame(maxWidth: 1000)
        
        
        VStack(alignment: .leading,spacing: 8) {
          Text("Simple Dictation")
            .fontWeight(.medium)
            .font(.title3)
          Text("Use your configured hotkey behavior and start talking. Chirp transcribes your audio locally with Parakeet through transcribe.cpp and copies the result to your clipboard. Apple Speech remains available as a fallback.")
            .frame(maxWidth: .infinity, alignment: .leading)
          
          Text("Turn on automatic paste to insert the transcript into your active text field as soon as processing finishes.")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
      }
    }
  }
}

#Preview {
  HowItWorksView()
}
