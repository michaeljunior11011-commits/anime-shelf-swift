import CryptoKit
import ImageIO
import SwiftUI
import UIKit

actor ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let directory: URL
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 64 * 1_024 * 1_024,
            diskCapacity: 250 * 1_024 * 1_024
        )
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = caches.appendingPathComponent("AnimeShelf/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 180
        memory.totalCostLimit = 80 * 1_024 * 1_024
    }

    func image(for url: URL, targetSize: CGSize, scale: CGFloat) async throws -> UIImage {
        let key = cacheKey(url: url, targetSize: targetSize, scale: scale)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return try await task.value }

        let fileURL = directory.appendingPathComponent(hash(url.absoluteString))
        let requestSession = session
        let task = Task<UIImage, Error> {
            let data: Data
            if let diskData = try? Data(contentsOf: fileURL), !diskData.isEmpty {
                data = diskData
            } else {
                data = try await Self.download(url: url, session: requestSession)
                try? data.write(to: fileURL, options: .atomic)
            }
            guard let image = Self.downsample(data: data, targetSize: targetSize, scale: scale) else {
                throw ImagePipelineError.decodeFailed
            }
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let image = try await task.value
        memory.setObject(image, forKey: key as NSString, cost: image.memoryCost)
        return image
    }

    func prefetch(_ urls: [URL], targetSize: CGSize, scale: CGFloat) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(12) {
                group.addTask {
                    _ = try? await self.image(for: url, targetSize: targetSize, scale: scale)
                }
            }
        }
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    private static func download(url: URL, session: URLSession) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                var request = URLRequest(url: url)
                request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    throw ImagePipelineError.invalidResponse
                }
                return data
            } catch {
                lastError = error
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(450)) }
            }
        }
        throw lastError ?? ImagePipelineError.invalidResponse
    }

    private nonisolated static func downsample(data: Data, targetSize: CGSize, scale: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let dimension = max(targetSize.width, targetSize.height) * max(scale, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(dimension), 160)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func cacheKey(url: URL, targetSize: CGSize, scale: CGFloat) -> String {
        "\(url.absoluteString)|\(Int(targetSize.width))x\(Int(targetSize.height))@\(Int(scale))"
    }

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() + ".img"
    }
}

enum ImagePipelineError: Error {
    case invalidResponse
    case decodeFailed
}

@MainActor
private final class RemoteImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    func load(url: URL?, targetSize: CGSize, scale: CGFloat) async {
        image = nil
        failed = false
        guard let url else { failed = true; return }
        do {
            image = try await ImagePipeline.shared.image(for: url, targetSize: targetSize, scale: scale)
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}

struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let targetSize: CGSize
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        Group {
            if let image = loader.image { content(Image(uiImage: image)) }
            else { placeholder() }
        }
        .task(id: "\(url?.absoluteString ?? "nil")|\(targetSize.width)x\(targetSize.height)") {
            await loader.load(url: url, targetSize: targetSize, scale: displayScale)
        }
    }
}

extension UIImage {
    fileprivate var memoryCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
