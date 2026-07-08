import SwiftUI

struct WaveformView: View {
  static let barCount = 36

  let levels: [Float]

  @State private var previousLevels = Array(repeating: Float(0), count: WaveformView.barCount)
  @State private var targetLevels = Array(repeating: Float(0), count: WaveformView.barCount)
  @State private var transitionStart = Date()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
      Canvas { context, size in
        let displayLevels = interpolatedLevels(at: timeline.date)
        let barWidth: CGFloat = 2
        let spacing: CGFloat = 2
        let totalWidth = CGFloat(Self.barCount) * barWidth + CGFloat(Self.barCount - 1) * spacing
        var x = (size.width - totalWidth) / 2

        for level in displayLevels {
          let height = Self.height(for: level)
          let rect = CGRect(
            x: x,
            y: (size.height - height) / 2,
            width: barWidth,
            height: height
          )

          context.fill(
            Path(roundedRect: rect, cornerRadius: barWidth / 2),
            with: .color(.primary)
          )

          x += barWidth + spacing
        }
      }
    }
    .frame(width: 142, height: 24)
    .mask(edgeFadeMask)
    .accessibilityLabel("Live input waveform")
    .onAppear {
      let displayLevels = Self.displayLevels(from: levels)
      previousLevels = displayLevels
      targetLevels = displayLevels
      transitionStart = Date()
    }
    .onChange(of: levels) { _, newLevels in
      let now = Date()
      previousLevels = interpolatedLevels(at: now)
      targetLevels = Self.displayLevels(from: newLevels)
      transitionStart = now
    }
  }

  private var edgeFadeMask: some View {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .black, location: 0.16),
        .init(color: .black, location: 0.84),
        .init(color: .clear, location: 1)
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private static func displayLevels(from levels: [Float]) -> [Float] {
    let recentLevels = Array(levels.suffix(Self.barCount))
    let paddingCount = max(0, Self.barCount - recentLevels.count)
    let leadingPadding = paddingCount / 2
    let trailingPadding = paddingCount - leadingPadding

    return Array(repeating: Float(0), count: leadingPadding)
      + recentLevels
      + Array(repeating: Float(0), count: trailingPadding)
  }

  private func interpolatedLevels(at date: Date) -> [Float] {
    let elapsed = date.timeIntervalSince(transitionStart)
    let progress = min(max(elapsed / Self.levelInterpolationDuration, 0), 1)
    let easedProgress = 1 - pow(1 - Float(progress), 3)

    return zip(previousLevels, targetLevels).map { previousLevel, targetLevel in
      previousLevel + (targetLevel - previousLevel) * easedProgress
    }
  }

  private static func height(for level: Float) -> CGFloat {
    let level = CGFloat(level)
    guard level > 0.012 else {
      return 3
    }

    let noiseReducedLevel = max(level - 0.012, 0)
    let scaledLevel = min(noiseReducedLevel * 2.4, 1)
    let emphasizedLevel = pow(scaledLevel, 0.55)
    return 3 + emphasizedLevel * 18
  }

  private static let levelInterpolationDuration: TimeInterval = 0.08
}
