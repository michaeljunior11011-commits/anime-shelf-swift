import SwiftUI

struct TestView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: [.red, .orange, .black], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                VStack(spacing: 28) {
                    Text("AFTER UPDATE").font(.system(size: 40, weight: .black, design: .rounded)).foregroundStyle(.black)
                    Text(String(format: "%.2f", t.truncatingRemainder(dividingBy: 100))).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(.black)
                    RoundedRectangle(cornerRadius: 26).fill(.white).frame(width: 155, height: 112).rotationEffect(.degrees(t * 140)).offset(y: CGFloat(cos(t * 2) * 75))
                }
            }
        }
    }
}

#Preview("RecordVideo after") { TestView() }
