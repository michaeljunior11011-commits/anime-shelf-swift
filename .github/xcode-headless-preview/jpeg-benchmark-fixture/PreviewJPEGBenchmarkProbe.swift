import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import Network

private struct JPEGConfiguration {
    let scale: CGFloat
    let quality: CGFloat
    let label: String
}

private struct CapturedBenchmarkFrame: @unchecked Sendable {
    let image: CGImage
    let configurationIndex: Int
    let captureMs: Double
}

private final class BenchmarkReporter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.codex.preview.benchmark.report", qos: .utility)
    private var connection: NWConnection?

    func report(_ header: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let headerData = try? JSONSerialization.data(withJSONObject: header) else { return }
            var packet = Data()
            var length = UInt32(headerData.count).bigEndian
            Swift.withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            packet.append(headerData)
            length = UInt32(0).bigEndian
            Swift.withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            let connection = NWConnection(host: "127.0.0.1", port: 8788, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                connection.send(content: packet, completion: .idempotent)
                self?.queue.asyncAfter(deadline: .now() + .milliseconds(750)) {
                    connection.cancel()
                    self?.connection = nil
                }
            }
            connection.start(queue: self.queue)
        }
    }
}

private final class BenchmarkEncoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.codex.preview.benchmark.jpeg", qos: .userInitiated)
    private let lock = NSLock()
    private let configurations: [JPEGConfiguration]
    private var processing = false
    private var pending: CapturedBenchmarkFrame?
    private var finishCaptureSummary: [[String: Any]]?
    private var metrics: [[[String: Any]]]
    private var replaced: [Int]
    private var encodeFailures: [Int]

    init(configurations: [JPEGConfiguration]) {
        self.configurations = configurations
        self.metrics = Array(repeating: [[String: Any]](), count: configurations.count)
        self.replaced = Array(repeating: 0, count: configurations.count)
        self.encodeFailures = Array(repeating: 0, count: configurations.count)
    }

    func submit(_ frame: CapturedBenchmarkFrame) {
        lock.lock()
        if processing {
            if let old = pending { replaced[old.configurationIndex] += 1 }
            pending = frame
            lock.unlock()
            return
        }
        processing = true
        lock.unlock()
        queue.async { [weak self] in self?.encode(frame) }
    }

    func finishWhenDrained(captureSummary: [[String: Any]], completion: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock()
        finishCaptureSummary = captureSummary
        let ready = !processing && pending == nil
        if !ready { self.completion = completion }
        lock.unlock()
        if ready { queue.async { [weak self] in self?.finish(completion: completion) } }
    }

    private var completion: (@Sendable ([String: Any]) -> Void)?

    private func encode(_ frame: CapturedBenchmarkFrame) {
        let start = CACurrentMediaTime()
        let data = jpegData(image: frame.image, quality: configurations[frame.configurationIndex].quality)
        let encodeMs = (CACurrentMediaTime() - start) * 1000
        lock.lock()
        if let data {
            metrics[frame.configurationIndex].append([
                "captureMs": frame.captureMs,
                "encodeMs": encodeMs,
                "jpegBytes": data.count,
                "width": frame.image.width,
                "height": frame.image.height
            ])
        } else {
            encodeFailures[frame.configurationIndex] += 1
        }
        let next = pending
        pending = nil
        if next == nil { processing = false }
        let shouldFinish = next == nil && finishCaptureSummary != nil
        let finalCompletion = shouldFinish ? completion : nil
        if shouldFinish { completion = nil }
        lock.unlock()
        if let next { queue.async { [weak self] in self?.encode(next) } }
        else if let finalCompletion { finish(completion: finalCompletion) }
    }

    private func finish(completion: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock()
        guard let captureSummary = finishCaptureSummary else { lock.unlock(); return }
        finishCaptureSummary = nil
        let output: [[String: Any]] = configurations.enumerated().map { index, configuration in
            let samples = metrics[index]
            func values(_ key: String) -> [Double] { samples.compactMap { $0[key] as? Double } }
            let capture = values("captureMs")
            let encode = values("encodeMs")
            let sizes = samples.compactMap { ($0["jpegBytes"] as? Int).map(Double.init) }
            return [
                "configurationIndex": index,
                "label": configuration.label,
                "scale": configuration.scale,
                "quality": configuration.quality,
                "captureAttempts": captureSummary[index]["captureAttempts"] ?? 0,
                "durationSeconds": captureSummary[index]["durationSeconds"] ?? 20.0,
                "encodedFrames": samples.count,
                "actualFPS": Double(samples.count) / 20.0,
                "replacedPendingFrames": replaced[index],
                "encodeFailures": encodeFailures[index],
                "captureAverageMs": average(capture),
                "encodeAverageMs": average(encode),
                "encodeP95Ms": percentile(encode, 0.95),
                "jpegAverageBytes": average(sizes),
                "jpegP95Bytes": percentile(sizes, 0.95),
                "width": samples.first?["width"] ?? 0,
                "height": samples.first?["height"] ?? 0
            ]
        }
        lock.unlock()
        completion(["type": "end", "reason": "jpeg-resolution-benchmark", "configurations": output])
    }

    private func jpegData(image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}

struct PreviewJPEGBenchmarkProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewJPEGBenchmarkProbeView { PreviewJPEGBenchmarkProbeView() }
    func updateUIView(_ uiView: PreviewJPEGBenchmarkProbeView, context: Context) {}
}

@MainActor
final class PreviewJPEGBenchmarkProbeView: UIView {
    private let configurations = [
        JPEGConfiguration(scale: 0.5, quality: 0.5, label: "scale-0.5_quality-0.5"),
        JPEGConfiguration(scale: 0.5, quality: 0.35, label: "scale-0.5_quality-0.35"),
        JPEGConfiguration(scale: 0.4, quality: 0.5, label: "scale-0.4_quality-0.5"),
        JPEGConfiguration(scale: 0.4, quality: 0.35, label: "scale-0.4_quality-0.35")
    ]
    private lazy var encoder = BenchmarkEncoder(configurations: configurations)
    private let reporter = BenchmarkReporter()
    private var displayLink: CADisplayLink?
    private var phase = 0
    private var phaseStartedAt: CFTimeInterval = 0
    private var lastCaptureAt: CFTimeInterval = -1
    private var captureAttempts = [0, 0, 0, 0]

    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 20, preferred: 20)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let keyWindow = keyPreviewWindow() else { return }
        if phaseStartedAt == 0 { phaseStartedAt = link.timestamp }
        if link.timestamp - phaseStartedAt >= 20 {
            if phase == configurations.count - 1 { finish(link); return }
            phase += 1; phaseStartedAt = link.timestamp; lastCaptureAt = -1
            return
        }
        guard lastCaptureAt < 0 || link.timestamp - lastCaptureAt >= 0.048 else { return }
        lastCaptureAt = link.timestamp
        captureAttempts[phase] += 1
        let captureStart = CACurrentMediaTime()
        let format = UIGraphicsImageRendererFormat()
        format.scale = configurations[phase].scale
        let bounds = keyWindow.bounds
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in _ = keyWindow.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        let captureMs = (CACurrentMediaTime() - captureStart) * 1000
        if let cgImage = image.cgImage { encoder.submit(CapturedBenchmarkFrame(image: cgImage, configurationIndex: phase, captureMs: captureMs)) }
    }

    private func finish(_ link: CADisplayLink) {
        link.invalidate(); displayLink = nil
        let summary: [[String: Any]] = captureAttempts.map { ["captureAttempts": $0, "durationSeconds": 20.0] }
        encoder.finishWhenDrained(captureSummary: summary) { [weak self] report in self?.reporter.report(report) }
    }

    private func keyPreviewWindow() -> UIWindow? {
        if let ownWindow = window, ownWindow.isKeyWindow { return ownWindow }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow } ?? window
    }
}
