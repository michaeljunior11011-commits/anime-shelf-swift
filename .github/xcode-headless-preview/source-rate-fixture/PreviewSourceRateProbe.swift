import SwiftUI
import UIKit
import ReplayKit
import CoreMedia
import CoreVideo
import Network

private final class SourceRateReporter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.codex.preview.source-rate.report", qos: .utility)
    private var connection: NWConnection?

    func report(_ value: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let header = try? JSONSerialization.data(withJSONObject: value) else { return }
            var packet = Data()
            var length = UInt32(header.count).bigEndian
            Swift.withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            packet.append(header)
            length = UInt32(0).bigEndian
            Swift.withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            let connection = NWConnection(host: "127.0.0.1", port: 8789, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                connection.send(content: packet, completion: .idempotent)
                self?.queue.asyncAfter(deadline: .now() + .milliseconds(750)) {
                    connection.cancel(); self?.connection = nil
                }
            }
            connection.start(queue: self.queue)
        }
    }
}

private final class ScreenSampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleCount = 0
    private var markerSamples = 0
    private var width = 0
    private var height = 0
    private var pixelFormat = 0
    private var errors: [String] = []

    func record(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sampleWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sampleHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var isMarker = false
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let x = sampleWidth / 2; let y = sampleHeight / 2
            let pixel = base.assumingMemoryBound(to: UInt8.self).advanced(by: y * bytesPerRow + x * 4)
            let blue = Int(pixel[0]); let green = Int(pixel[1]); let red = Int(pixel[2])
            isMarker = red > 170 && green > 110 && blue < 110
        }
        lock.lock()
        sampleCount += 1
        if isMarker { markerSamples += 1 }
        width = sampleWidth; height = sampleHeight; pixelFormat = Int(CVPixelBufferGetPixelFormatType(pixelBuffer))
        lock.unlock()
    }

    func addError(_ error: Error?) { if let error { lock.lock(); errors.append(error.localizedDescription); lock.unlock() } }
    func summary() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["videoSampleBuffers": sampleCount, "previewMarkerSamples": markerSamples, "width": width, "height": height, "pixelFormat": pixelFormat, "errors": errors]
    }
}

struct PreviewSourceRateProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewSourceRateProbeView { PreviewSourceRateProbeView() }
    func updateUIView(_ uiView: PreviewSourceRateProbeView, context: Context) {}
}

@MainActor
final class PreviewSourceRateProbeView: UIView {
    private let targets = [30, 60]
    private var phase = 0
    private var displayLink: CADisplayLink?
    private var phaseStartedAt: CFTimeInterval = 0
    private var callbackCount = 0
    private var displayResults: [[String: Any]] = []
    private let screenCounter = ScreenSampleCounter()
    private let reporter = SourceRateReporter()
    private var screenStartedAt: CFTimeInterval = 0
    private var screenCaptureStarted = false

    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, displayLink == nil else { return }
        startDisplayPhase()
    }

    private func startDisplayPhase() {
        callbackCount = 0; phaseStartedAt = 0
        let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
        let preferred = Float(targets[phase])
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: preferred, preferred: preferred)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        if phaseStartedAt == 0 { phaseStartedAt = link.timestamp }
        callbackCount += 1
        let elapsed = link.timestamp - phaseStartedAt
        guard elapsed >= 10 else { return }
        displayResults.append(["preferredFPS": targets[phase], "durationSeconds": elapsed, "callbacks": callbackCount, "actualFPS": Double(callbackCount) / elapsed])
        link.invalidate(); displayLink = nil
        if phase + 1 < targets.count { phase += 1; startDisplayPhase() }
        else { startScreenCaptureProbe() }
    }

    private func startScreenCaptureProbe() {
        let recorder = RPScreenRecorder.shared()
        screenStartedAt = CACurrentMediaTime()
        guard recorder.isAvailable else { finish(recorderAvailable: false, startError: "RPScreenRecorder is unavailable") ; return }
        recorder.startCapture(handler: { [weak self] sampleBuffer, bufferType, error in
            self?.screenCounter.addError(error)
            if bufferType == .video { self?.screenCounter.record(sampleBuffer) }
        }, completionHandler: { [weak self] error in
            guard let self else { return }
            self.screenCounter.addError(error)
            self.screenCaptureStarted = error == nil
            if error != nil { self.finish(recorderAvailable: true, startError: error?.localizedDescription) }
            else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.stopScreenCapture() }
            }
        })
    }

    private func stopScreenCapture() {
        guard screenCaptureStarted else { finish(recorderAvailable: true, startError: nil); return }
        RPScreenRecorder.shared().stopCapture { [weak self] error in
            self?.screenCounter.addError(error)
            self?.finish(recorderAvailable: true, startError: error?.localizedDescription)
        }
    }

    private func finish(recorderAvailable: Bool, startError: String?) {
        let elapsed = screenStartedAt == 0 ? 0 : CACurrentMediaTime() - screenStartedAt
        reporter.report([
            "type": "end",
            "reason": "preview-source-rate-probe",
            "displayLink": displayResults,
            "screenRecorder": ["isAvailable": recorderAvailable, "durationSeconds": elapsed, "startOrStopError": startError ?? NSNull(), "samples": screenCounter.summary()]
        ])
    }
}
