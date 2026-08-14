import SwiftUI
import UIKit
import Network
import ImageIO
import UniformTypeIdentifiers

private struct CapturedFrame: @unchecked Sendable {
    let image: CGImage
    let index: Int
    let phaseIndex: Int
    let targetFPS: Int
    let phaseElapsedSeconds: Double
    let captureStartedEpochMs: Double
    let captureStartedMonotonic: CFTimeInterval
    let captureMs: Double
    let hierarchySucceeded: Bool
    let windowBounds: String
}

private final class SendCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable (NWError?, Bool) -> Void

    init(completion: @escaping @Sendable (NWError?, Bool) -> Void) { self.completion = completion }

    func finish(error: NWError?, timedOut: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completion(error, timedOut)
    }
}

private final class PreviewJPEGStreamPipeline: @unchecked Sendable {
    private let sessionID: String
    private let connection = NWConnection(host: "127.0.0.1", port: 8787, using: .tcp)
    private let networkQueue = DispatchQueue(label: "dev.codex.preview.network", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "dev.codex.preview.jpeg", qos: .userInitiated)
    private let stateLock = NSLock()
    private var ready = false
    private var processing = false
    private var pending: CapturedFrame?
    private var finishRequest: [[String: Any]]?
    private var replacedByPhase: [Int: Int] = [:]
    private var encodedByPhase: [Int: Int] = [:]
    private var encodeFailuresByPhase: [Int: Int] = [:]
    private var sendFailuresByPhase: [Int: Int] = [:]
    private var sendTimeoutsByPhase: [Int: Int] = [:]
    private var sentByPhase: [Int: Int] = [:]
    private var encodeTimesByPhase: [Int: [Double]] = [:]
    private var sendTimesByPhase: [Int: [Double]] = [:]
    private var receiveBuffer = Data()
    private var ackGates: [Int: SendCompletionGate] = [:]

    init(sessionID: String) {
        self.sessionID = sessionID
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.setReady(true)
            case .failed, .cancelled: self?.setReady(false)
            default: break
            }
        }
        connection.start(queue: networkQueue)
        receiveNext()
    }

    var isReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return ready
    }

    func submit(_ frame: CapturedFrame) {
        stateLock.lock()
        if processing {
            if let old = pending { replacedByPhase[old.phaseIndex, default: 0] += 1 }
            pending = frame
            stateLock.unlock()
            return
        }
        processing = true
        stateLock.unlock()
        processingQueue.async { [weak self] in self?.process(frame) }
    }

    func finishWhenDrained(phaseCaptureSummary: [[String: Any]]) {
        stateLock.lock()
        finishRequest = phaseCaptureSummary
        let shouldFinish = !processing && pending == nil
        stateLock.unlock()
        if shouldFinish { processingQueue.async { [weak self] in self?.sendEndIfReady() } }
    }

    private func process(_ frame: CapturedFrame) {
        let encodeStart = CACurrentMediaTime()
        guard let jpeg = encodeJPEG(frame.image) else {
            stateLock.lock(); encodeFailuresByPhase[frame.phaseIndex, default: 0] += 1; stateLock.unlock()
            completeCurrent()
            return
        }
        let encodeMs = (CACurrentMediaTime() - encodeStart) * 1000
        encodedByPhase[frame.phaseIndex, default: 0] += 1
        encodeTimesByPhase[frame.phaseIndex, default: []].append(encodeMs)
        let sendStartMonotonic = CACurrentMediaTime()
        let sendStartedEpochMs = Date().timeIntervalSince1970 * 1000
        let header: [String: Any] = [
            "type": "frame", "sessionID": sessionID, "index": frame.index,
            "phaseIndex": frame.phaseIndex, "targetFPS": frame.targetFPS,
            "phaseElapsedSeconds": frame.phaseElapsedSeconds,
            "captureStartedEpochMs": frame.captureStartedEpochMs,
            "sendStartedEpochMs": sendStartedEpochMs,
            "captureMs": frame.captureMs, "encodeMs": encodeMs,
            "jpegBytes": jpeg.count, "frameHash": jpeg.hashValue,
            "hierarchySucceeded": frame.hierarchySucceeded, "windowBounds": frame.windowBounds
        ]
        sendFramePacket(header: header, jpeg: jpeg, index: frame.index) { [weak self] error, timedOut in
            guard let self else { return }
            self.processingQueue.async {
                let networkSendMs = (CACurrentMediaTime() - sendStartMonotonic) * 1000
                let endToEndSendMs = (CACurrentMediaTime() - frame.captureStartedMonotonic) * 1000
                if error == nil { self.sentByPhase[frame.phaseIndex, default: 0] += 1 }
                else { self.sendFailuresByPhase[frame.phaseIndex, default: 0] += 1 }
                if timedOut { self.sendTimeoutsByPhase[frame.phaseIndex, default: 0] += 1 }
                self.sendTimesByPhase[frame.phaseIndex, default: []].append(networkSendMs)
                self.sendPacket(header: [
                    "type": "sendMetric", "sessionID": self.sessionID, "index": frame.index,
                    "phaseIndex": frame.phaseIndex, "targetFPS": frame.targetFPS,
                    "networkSendMs": networkSendMs, "endToEndSendMs": endToEndSendMs,
                    "sendTimedOut": timedOut
                ], jpeg: Data(), completion: { _, _ in })
                self.completeCurrent()
            }
        }
    }

    private func completeCurrent() {
        stateLock.lock()
        if let next = pending {
            pending = nil
            stateLock.unlock()
            processingQueue.async { [weak self] in self?.process(next) }
            return
        }
        processing = false
        let shouldFinish = finishRequest != nil
        stateLock.unlock()
        if shouldFinish { sendEndIfReady() }
    }

    private func sendEndIfReady() {
        stateLock.lock()
        guard !processing, pending == nil, let captureSummary = finishRequest else { stateLock.unlock(); return }
        finishRequest = nil
        let phaseIndexes = Array(Set(captureSummary.compactMap { $0["phaseIndex"] as? Int })).sorted()
        let phases: [[String: Any]] = phaseIndexes.map { phase in
            [
                "phaseIndex": phase,
                "replacedPendingFrames": replacedByPhase[phase, default: 0],
                "encodedFrames": encodedByPhase[phase, default: 0],
                "sentFrames": sentByPhase[phase, default: 0],
                "encodeFailures": encodeFailuresByPhase[phase, default: 0],
                "sendFailures": sendFailuresByPhase[phase, default: 0],
                "sendTimeouts": sendTimeoutsByPhase[phase, default: 0]
            ]
        }
        stateLock.unlock()
        sendPacket(header: [
            "type": "end", "sessionID": sessionID,
            "reason": "completed-10-15-20-fps-phases",
            "phaseCaptureSummary": captureSummary,
            "pipelineSummary": ["phases": phases]
        ], jpeg: Data(), completion: { _, _ in })
    }

    private func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func sendPacket(header: [String: Any], jpeg: Data, completion: @escaping @Sendable (NWError?, Bool) -> Void) {
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { completion(nil, false); return }
        var packet = Data()
        append(UInt32(headerData.count), to: &packet); packet.append(headerData)
        append(UInt32(jpeg.count), to: &packet); packet.append(jpeg)
        let gate = SendCompletionGate(completion: completion)
        connection.send(content: packet, completion: .contentProcessed { error in gate.finish(error: error, timedOut: false) })
        networkQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { gate.finish(error: nil, timedOut: true) }
    }

    private func sendFramePacket(header: [String: Any], jpeg: Data, index: Int, completion: @escaping @Sendable (NWError?, Bool) -> Void) {
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { completion(nil, false); return }
        var packet = Data()
        append(UInt32(headerData.count), to: &packet); packet.append(headerData)
        append(UInt32(jpeg.count), to: &packet); packet.append(jpeg)
        let gate = SendCompletionGate(completion: completion)
        stateLock.lock(); ackGates[index] = gate; stateLock.unlock()
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.finishAck(index: index, error: error, timedOut: false) }
        })
        networkQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.finishAck(index: index, error: nil, timedOut: true)
        }
    }

    private func finishAck(index: Int, error: NWError?, timedOut: Bool) {
        stateLock.lock(); let gate = ackGates.removeValue(forKey: index); stateLock.unlock()
        gate?.finish(error: error, timedOut: timedOut)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content { self.receiveBuffer.append(content); self.parseAcknowledgements() }
            if !isComplete && error == nil { self.receiveNext() }
        }
    }

    private func parseAcknowledgements() {
        while receiveBuffer.count >= 8 {
            let headerLength = Int(readUInt32(receiveBuffer, at: 0))
            guard headerLength <= 1_048_576, receiveBuffer.count >= 8 + headerLength else { return }
            let jpegLength = Int(readUInt32(receiveBuffer, at: 4 + headerLength))
            let packetLength = 8 + headerLength + jpegLength
            guard receiveBuffer.count >= packetLength else { return }
            let headerData = receiveBuffer.subdata(in: 4..<(4 + headerLength))
            receiveBuffer.removeSubrange(0..<packetLength)
            if let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
               header["type"] as? String == "ack", let index = header["index"] as? Int {
                finishAck(index: index, error: nil, timedOut: false)
            }
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func setReady(_ value: Bool) {
        stateLock.lock(); ready = value; stateLock.unlock()
    }
}

struct PreviewLiveStreamProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewLiveStreamProbeView { PreviewLiveStreamProbeView() }
    func updateUIView(_ uiView: PreviewLiveStreamProbeView, context: Context) {}
}

@MainActor
final class PreviewLiveStreamProbeView: UIView {
    private let sessionID = UUID().uuidString
    private lazy var pipeline = PreviewJPEGStreamPipeline(sessionID: sessionID)
    private let targets = [10, 15, 20]
    private var displayLink: CADisplayLink?
    private var phaseIndex = 0
    private var phaseStartedAt: CFTimeInterval = 0
    private var lastCaptureAt: CFTimeInterval = -1
    private var frameIndex = 0
    private var captureTimes = [[Double](), [Double](), [Double]()]
    private var captureAttempts = [0, 0, 0]

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
        guard pipeline.isReady, let keyWindow = keyPreviewWindow() else { return }
        if phaseStartedAt == 0 { phaseStartedAt = link.timestamp }
        let phaseElapsed = link.timestamp - phaseStartedAt
        if phaseElapsed >= 30 {
            if phaseIndex == targets.count - 1 { finish(link: link); return }
            phaseIndex += 1; phaseStartedAt = link.timestamp; lastCaptureAt = -1
            return
        }
        let targetFPS = targets[phaseIndex]
        guard lastCaptureAt < 0 || link.timestamp - lastCaptureAt >= (1.0 / Double(targetFPS)) - 0.002 else { return }
        lastCaptureAt = link.timestamp
        captureAttempts[phaseIndex] += 1
        let captureStartedEpochMs = Date().timeIntervalSince1970 * 1000
        let captureStart = CACurrentMediaTime()
        let bounds = keyWindow.bounds
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        var hierarchySucceeded = false
        let image = renderer.image { _ in hierarchySucceeded = keyWindow.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        let captureMs = (CACurrentMediaTime() - captureStart) * 1000
        captureTimes[phaseIndex].append(captureMs)
        guard let cgImage = image.cgImage else { return }
        pipeline.submit(CapturedFrame(
            image: cgImage, index: frameIndex, phaseIndex: phaseIndex, targetFPS: targetFPS,
            phaseElapsedSeconds: phaseElapsed, captureStartedEpochMs: captureStartedEpochMs,
            captureStartedMonotonic: captureStart,
            captureMs: captureMs, hierarchySucceeded: hierarchySucceeded,
            windowBounds: NSCoder.string(for: bounds)
        ))
        frameIndex += 1
    }

    private func finish(link: CADisplayLink) {
        link.invalidate(); displayLink = nil
        let summary: [[String: Any]] = targets.enumerated().map { index, target in
            let values = captureTimes[index]
            return [
                "phaseIndex": index, "targetFPS": target, "durationSeconds": 30.0,
                "captureAttempts": captureAttempts[index],
                "captureAverageMs": values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            ]
        }
        pipeline.finishWhenDrained(phaseCaptureSummary: summary)
    }

    private func keyPreviewWindow() -> UIWindow? {
        if let ownWindow = window, ownWindow.isKeyWindow { return ownWindow }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow } ?? window
    }
}
