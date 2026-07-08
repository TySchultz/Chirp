//
//  PrivacyView.swift
//  Chirp
//
//

import SwiftUI

struct PrivacyView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        
        Image("Privacy")
          .resizable()
          .aspectRatio(1.77, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 8.0, style: .continuous))
          .frame(maxWidth: 1000)
      }
    }
  }
}

#Preview {
  PrivacyView()
}
