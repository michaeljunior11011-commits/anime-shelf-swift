import SwiftUI

struct TestView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: [.indigo, .black, .teal], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                VStack(spacing: 34) {
                    Text("JPEG BENCHMARK").font(.system(size: 42, weight: .black, design: .rounded)).foregroundStyle(.yellow)
                    Text(String(format: "%.2f", phase.truncatingRemainder(dividingBy: 100))).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    RoundedRectangle(cornerRadius: 30).fill(.cyan).frame(width: 105, height: 105).rotationEffect(.degrees(phase * 120)).offset(x: CGFloat(sin(phase * 2.4) * 110))
                }
                PreviewJPEGBenchmarkProbe().frame(width: 1, height: 1).allowsHitTesting(false)
            }
        }
    }
}

#Preview("JPEG resolution benchmark") { TestView() }
