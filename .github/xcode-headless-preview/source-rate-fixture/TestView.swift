import SwiftUI

struct TestView: View {
    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.13, blue: 0.22).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 34).fill(Color(red: 0.95, green: 0.72, blue: 0.08)).frame(width: 160, height: 160)
            Text("SOURCE RATE").font(.system(size: 28, weight: .black, design: .rounded)).foregroundStyle(.black)
            PreviewSourceRateProbe().frame(width: 1, height: 1).allowsHitTesting(false)
        }
    }
}

#Preview("Source rate probe") { TestView() }
