import SwiftUI

struct TestView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: [.indigo, .cyan, .black], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                VStack(spacing: 28) {
                    Text("BEFORE UPDATE").font(.system(size: 40, weight: .black, design: .rounded)).foregroundStyle(.white)
                    Text(String(format: "%.2f", t.truncatingRemainder(dividingBy: 100))).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    Circle().fill(.yellow).frame(width: 118, height: 118).rotationEffect(.degrees(t * 180)).offset(x: CGFloat(sin(t * 2) * 95))
                }
            }
        }
    }
}

#Preview("RecordVideo before") { TestView() }
