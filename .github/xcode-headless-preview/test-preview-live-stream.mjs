import { spawn } from "node:child_process";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const outputDirectory = path.resolve(process.argv[2] ?? "live-preview-stream-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const fixtureRoot = path.dirname(path.resolve(process.env.PREVIEW_SOURCE_PATH ?? ""));
const sourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const results = { startedAt: new Date().toISOString() };
await mkdir(outputDirectory, { recursive: true });

const helperSource = `import SwiftUI
import UIKit
import Network

final class PreviewTCPFrameSender: @unchecked Sendable {
    private let connection = NWConnection(host: "127.0.0.1", port: 8787, using: .tcp)
    private let stateLock = NSLock()
    private var ready = false
    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ready
    }

    init() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.setReady(true)
            case .failed, .cancelled: self.setReady(false)
            default: break
            }
        }
        connection.start(queue: .main)
    }

    private func setReady(_ value: Bool) {
        stateLock.lock()
        ready = value
        stateLock.unlock()
    }

    func send(header: [String: Any], jpeg: Data = Data()) -> Bool {
        guard isReady,
              let headerData = try? JSONSerialization.data(withJSONObject: header, options: []) else { return false }
        var packet = Data()
        append(UInt32(headerData.count), to: &packet)
        packet.append(headerData)
        append(UInt32(jpeg.count), to: &packet)
        packet.append(jpeg)
        connection.send(content: packet, completion: .contentProcessed { _ in })
        return true
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

struct PreviewLiveStreamProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewLiveStreamProbeView { PreviewLiveStreamProbeView() }
    func updateUIView(_ uiView: PreviewLiveStreamProbeView, context: Context) {}
}

@MainActor
final class PreviewLiveStreamProbeView: UIView {
    private let sender = PreviewTCPFrameSender()
    private let sessionID = UUID().uuidString
    private var displayLink: CADisplayLink?
    private var streamStartedAt: CFTimeInterval = 0
    private var waitingStartedAt = CACurrentMediaTime()
    private var lastCaptureAt: CFTimeInterval = -1
    private var attemptedFrames = 0
    private var sentFrames = 0
    private var droppedFrames = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 10, preferred: 10)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let keyWindow = keyPreviewWindow() else { return }
        if streamStartedAt == 0 {
            guard sender.isReady else {
                if CACurrentMediaTime() - waitingStartedAt > 12 { finish(reason: "receiver-timeout") }
                return
            }
            streamStartedAt = link.timestamp
        }

        let elapsed = link.timestamp - streamStartedAt
        if elapsed >= 30 {
            finish(reason: "completed-30-seconds")
            return
        }
        guard lastCaptureAt < 0 || link.timestamp - lastCaptureAt >= 0.099 else { return }
        lastCaptureAt = link.timestamp
        attemptedFrames += 1

        let captureStart = CACurrentMediaTime()
        let bounds = keyWindow.bounds
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        var hierarchySucceeded = false
        let image = renderer.image { _ in
            hierarchySucceeded = keyWindow.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let captureMs = (CACurrentMediaTime() - captureStart) * 1000

        let encodeStart = CACurrentMediaTime()
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            droppedFrames += 1
            return
        }
        let encodeMs = (CACurrentMediaTime() - encodeStart) * 1000
        let header: [String: Any] = [
            "type": "frame",
            "sessionID": sessionID,
            "index": sentFrames,
            "elapsedSeconds": elapsed,
            "captureMs": captureMs,
            "encodeMs": encodeMs,
            "jpegBytes": jpeg.count,
            "frameHash": jpeg.hashValue,
            "hierarchySucceeded": hierarchySucceeded,
            "windowBounds": NSCoder.string(for: bounds)
        ]
        if sender.send(header: header, jpeg: jpeg) { sentFrames += 1 } else { droppedFrames += 1 }
    }

    private func keyPreviewWindow() -> UIWindow? {
        if let ownWindow = window, ownWindow.isKeyWindow { return ownWindow }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? window
    }

    private func finish(reason: String) {
        guard let link = displayLink else { return }
        link.invalidate()
        displayLink = nil
        _ = sender.send(header: [
            "type": "end",
            "sessionID": sessionID,
            "reason": reason,
            "attemptedFrames": attemptedFrames,
            "sentFrames": sentFrames,
            "droppedFrames": droppedFrames,
            "durationSeconds": streamStartedAt > 0 ? CACurrentMediaTime() - streamStartedAt : 0
        ])
    }
}
`;

const previewSource = `import SwiftUI

struct TestView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: [.indigo, .black, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                VStack(spacing: 34) {
                    Text("LIVE PREVIEW")
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.2f", phase.truncatingRemainder(dividingBy: 100)))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    HStack(spacing: 22) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(index == Int(phase * 2).quotientAndRemainder(dividingBy: 3).remainder ? .cyan : .white.opacity(0.18))
                                .frame(width: 54, height: 54)
                        }
                    }
                    RoundedRectangle(cornerRadius: 30)
                        .fill(.cyan)
                        .frame(width: 105, height: 105)
                        .rotationEffect(.degrees(phase * 120))
                        .offset(x: CGFloat(sin(phase * 2.4) * 110))
                }
                PreviewLiveStreamProbe().frame(width: 1, height: 1).allowsHitTesting(false)
            }
        }
    }
}

#Preview("Live TCP stream") { TestView() }
`;

function decodedResult(result) {
  if (result?.structuredContent) return result.structuredContent;
  const text = result?.content?.filter((item) => item.type === "text").map((item) => item.text).join("\n");
  if (!text) return result;
  try { return JSON.parse(text); } catch { return { text }; }
}

async function call(client, name, args, timeout) {
  const raw = await client.request(
    { method: "tools/call", params: { name, arguments: args } },
    CompatibilityCallToolResultSchema,
    { timeout, resetTimeoutOnProgress: true },
  );
  const decoded = decodedResult(raw);
  results.mcpCalls ??= [];
  results.mcpCalls.push({ name, arguments: args, result: decoded });
  if (raw?.isError) throw new Error(`${name} failed: ${JSON.stringify(decoded)}`);
  return decoded;
}

async function waitForJSON(url, predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try {
      last = await fetch(url, { cache: "no-store" }).then((response) => response.json());
      if (predicate(last)) return last;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Timed out waiting for ${url}. Last response: ${JSON.stringify(last)}`);
}

let receiver;
let client;
try {
  if (!projectPath || !fixtureRoot) throw new Error("Preview fixture paths are required.");
  await writeFile(path.join(fixtureRoot, "PreviewLiveStreamProbe.swift"), helperSource, "utf8");
  await writeFile(path.join(fixtureRoot, "TestView.swift"), previewSource, "utf8");
  await writeFile(path.join(outputDirectory, "PreviewLiveStreamProbe.swift"), helperSource, "utf8");
  await writeFile(path.join(outputDirectory, "TestView.swift"), previewSource, "utf8");

  receiver = spawn(process.execPath, [path.resolve(".github/xcode-headless-preview/live-preview-receiver.mjs"), outputDirectory], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env },
  });
  let receiverLog = "";
  receiver.stdout.on("data", (chunk) => { receiverLog += chunk; process.stdout.write(chunk); });
  receiver.stderr.on("data", (chunk) => { receiverLog += chunk; process.stderr.write(chunk); });
  await waitForJSON("http://127.0.0.1:8080/health", (value) => value.ok, 20_000);

  const transport = new StdioClientTransport({ command: "xcrun", args: ["mcpbridge"], env: { ...process.env }, stderr: "pipe" });
  transport.stderr?.on("data", (chunk) => process.stderr.write(chunk));
  client = new Client({ name: "preview-live-stream-test", version: "1.0.0" });
  await client.connect(transport, { timeout: 180_000 });
  const opened = await call(client, "XcodeOpenWorkspace", { path: projectPath }, 180_000);
  const workspaceIdentifier = opened.workspaceIdentifier ?? projectPath;
  results.renderResult = await call(client, "RenderPreview", {
    workspaceIdentifier,
    sourceFilePath,
    previewDefinitionIndexInFile: 0,
    timeout: 360,
  }, 420_000);

  results.receiverStats = await waitForJSON("http://127.0.0.1:8080/stats", (value) => value.complete && value.videoResult, 60_000);
  results.viewerHTMLServed = (await fetch("http://127.0.0.1:8080/")).ok;
  results.verdict = results.receiverStats.frameCount >= 30 && results.receiverStats.uniqueFrameCount > 10
    ? "LIVE_TCP_PREVIEW_STREAM_CONFIRMED"
    : "STREAM_COMPLETED_WITH_INSUFFICIENT_MOTION";
  await writeFile(path.join(outputDirectory, "receiver.log"), receiverLog, "utf8");
} catch (error) {
  results.verdict = "TEST_FAILED";
  results.error = error instanceof Error ? error.stack ?? error.message : String(error);
  process.exitCode = 1;
} finally {
  results.finishedAt = new Date().toISOString();
  await writeFile(path.join(outputDirectory, "test-results.json"), JSON.stringify(results, null, 2), "utf8");
  if (client) await client.close();
  if (receiver && !receiver.killed) receiver.kill("SIGTERM");
}
