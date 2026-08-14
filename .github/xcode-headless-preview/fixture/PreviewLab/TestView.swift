import SwiftUI

struct TestView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Swift Lab Live")
                .font(.largeTitle.bold())
                .foregroundStyle(.cyan)
        }
    }
}

#Preview {
    TestView()
}

