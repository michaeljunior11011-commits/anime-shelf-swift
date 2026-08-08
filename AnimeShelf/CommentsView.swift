import SwiftUI

struct CommentsView: View {
    let episodeID: String
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [RemoteComment] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("جاري تحميل التعليقات…")
                } else if let errorMessage {
                    ContentUnavailableView("التعليقات غير متاحة", systemImage: "text.bubble", description: Text(errorMessage))
                } else if comments.isEmpty {
                    ContentUnavailableView("لا توجد تعليقات", systemImage: "text.bubble")
                } else {
                    List(comments) { comment in
                        HStack(alignment: .top, spacing: 12) {
                            AsyncImage(url: comment.avatarURL) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                            }
                            .frame(width: 42, height: 42)
                            .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(comment.author).font(.headline)
                                    Spacer()
                                    Text(comment.date).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(comment.body).font(.body)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("التعليقات")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إغلاق") { dismiss() }
                }
            }
            .task { await load() }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func load() async {
        do {
            comments = try await AnimeCloudCommentsService.shared.comments(episodeID: episodeID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
