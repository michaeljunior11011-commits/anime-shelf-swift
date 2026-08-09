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
                    ProgressView("Loading")
                } else if let errorMessage {
                    ContentUnavailableView("Comments unavailable", systemImage: "text.bubble", description: Text(errorMessage))
                } else if comments.isEmpty {
                    ContentUnavailableView("No comments", systemImage: "text.bubble")
                } else {
                    List(comments) { comment in
                        HStack(alignment: .top, spacing: 12) {
                            CachedRemoteImage(url: comment.avatarURL, targetSize: CGSize(width: 44, height: 44)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
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
            .navigationTitle("Comments")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await load() }
        }
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
