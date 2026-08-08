import SwiftUI

extension View {
    func animeGlass(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        let glass = Glass.regular
            .tint(Color.cyan.opacity(0.16))
            .interactive(interactive)
        return glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct GlassSectionTitle: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.title3.bold())
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular.tint(.cyan.opacity(0.12)), in: Capsule())
    }
}
