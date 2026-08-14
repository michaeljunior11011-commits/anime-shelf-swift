import { createHash } from "node:crypto";
import { execFile as execFileCallback } from "node:child_process";
import { copyFile, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const execFile = promisify(execFileCallback);
const outputDirectory = path.resolve(process.argv[2] ?? "preview-self-capture-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const fixtureRoot = path.dirname(path.resolve(process.env.PREVIEW_SOURCE_PATH ?? ""));
const sourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const results = { startedAt: new Date().toISOString() };

await mkdir(outputDirectory, { recursive: true });

const helperSource = `import SwiftUI
import UIKit

struct PreviewSelfCaptureProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewCaptureProbeView {
        PreviewCaptureProbeView()
    }

    func updateUIView(_ uiView: PreviewCaptureProbeView, context: Context) {}
}

@MainActor
final class PreviewCaptureProbeView: UIView {
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var lastCaptureAt: CFTimeInterval = -1
    private var frameIndex = 0
    private let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexPreviewSelfCapture", isDirectory: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, displayLink == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.startCapture()
        }
    }

    private func startCapture() {
        guard displayLink == nil, window != nil else { return }
        writeDiagnostics(completed: false)
        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        let elapsed = link.timestamp - startedAt
        if elapsed >= 3.0 {
            captureFrame()
            link.invalidate()
            displayLink = nil
            writeDiagnostics(completed: true)
            return
        }
        guard lastCaptureAt < 0 || link.timestamp - lastCaptureAt >= 0.15 else { return }
        lastCaptureAt = link.timestamp
        captureFrame()
    }

    private func captureFrame() {
        guard let previewWindow = window else { return }
        let bounds = previewWindow.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        var hierarchySucceeded = false
        let image = renderer.image { _ in
            hierarchySucceeded = previewWindow.drawHierarchy(in: bounds, afterScreenUpdates: true)
            if !hierarchySucceeded, let context = UIGraphicsGetCurrentContext() {
                previewWindow.layer.render(in: context)
            }
        }
        let filename = String(format: "frame-%03d-%@.png", frameIndex, hierarchySucceeded ? "hierarchy" : "layer")
        if let data = image.pngData() {
            try? data.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
            frameIndex += 1
        }
    }

    private func writeDiagnostics(completed: Bool) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let sceneDescriptions: [[String: Any]] = scenes.map { scene in
            [
                "persistentIdentifier": scene.session.persistentIdentifier,
                "activationState": scene.activationState.rawValue,
                "windows": scene.windows.enumerated().map { index, item in
                    [
                        "index": index,
                        "class": NSStringFromClass(type(of: item)),
                        "isKeyWindow": item.isKeyWindow,
                        "isHidden": item.isHidden,
                        "alpha": item.alpha,
                        "level": item.windowLevel.rawValue,
                        "bounds": NSCoder.string(for: item.bounds),
                        "rootViewController": item.rootViewController.map { NSStringFromClass(type(of: $0)) } ?? "nil",
                        "containsProbe": item === self.window
                    ] as [String: Any]
                }
            ]
        }
        let payload: [String: Any] = [
            "completed": completed,
            "capturedFrames": frameIndex,
            "connectedSceneCount": scenes.count,
            "scenes": sceneDescriptions,
            "probeWindowClass": window.map { NSStringFromClass(type(of: $0)) } ?? "nil",
            "probeWindowBounds": window.map { NSCoder.string(for: $0.bounds) } ?? "nil",
            "temporaryDirectory": outputDirectory.path
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outputDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }
}
`;

const previewSource = `import SwiftUI

struct TestView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(
                    colors: [.purple, .black, .blue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 28) {
                    Text("SELF CAPTURE")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(.yellow)

                    Text(String(format: "%.2f", phase.truncatingRemainder(dividingBy: 100)))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)

                    Circle()
                        .fill(.cyan)
                        .frame(width: 82, height: 82)
                        .offset(x: CGFloat(sin(phase * 3.0) * 115.0))
                }

                PreviewSelfCaptureProbe()
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

#Preview("Internal self-capture") {
    TestView()
}
`;

function decodedResult(result) {
  if (result?.structuredContent) return result.structuredContent;
  const text = result?.content?.filter((item) => item.type === "text").map((item) => item.text).join("\n");
  if (!text) return result;
  try { return JSON.parse(text); } catch { return { text }; }
}

async function call(client, name, args, timeout = 60_000) {
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

async function runXcrun(args) {
  try {
    const { stdout = "", stderr = "" } = await execFile("xcrun", args, { maxBuffer: 20 * 1024 * 1024 });
    return { ok: true, stdout, stderr };
  } catch (error) {
    return { ok: false, stdout: error.stdout ?? "", stderr: error.stderr ?? "", error: error.message, code: error.code };
  }
}

function findSnapshotPath(result) {
  if (typeof result?.previewSnapshotPath === "string") return result.previewSnapshotPath;
  return JSON.stringify(result).match(/(?:\/[^"\\]+\.png)/i)?.[0];
}

function findBootedDevice(jsonText) {
  const parsed = JSON.parse(jsonText);
  for (const [runtime, devices] of Object.entries(parsed.devices ?? {})) {
    const device = devices.find((candidate) => candidate.state === "Booted");
    if (device) return { runtime, ...device };
  }
  return undefined;
}

async function locateCaptureDirectories(root) {
  const found = [];
  async function visit(directory, depth) {
    if (depth > 7) return;
    let entries;
    try { entries = await readdir(directory, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const fullPath = path.join(directory, entry.name);
      if (entry.name === "CodexPreviewSelfCapture") found.push(fullPath);
      else await visit(fullPath, depth + 1);
    }
  }
  await visit(root, 0);
  return found;
}

async function fileFacts(filePath) {
  const bytes = await readFile(filePath);
  const width = bytes.subarray(1, 4).toString() === "PNG" ? bytes.readUInt32BE(16) : undefined;
  const height = bytes.subarray(1, 4).toString() === "PNG" ? bytes.readUInt32BE(20) : undefined;
  return { name: path.basename(filePath), bytes: bytes.length, width, height, sha256: createHash("sha256").update(bytes).digest("hex") };
}

const transport = new StdioClientTransport({ command: "xcrun", args: ["mcpbridge"], env: { ...process.env }, stderr: "pipe" });
transport.stderr?.on("data", (chunk) => process.stderr.write(chunk));
const client = new Client({ name: "preview-self-capture-test", version: "1.0.0" });
let connected = false;

try {
  if (!projectPath || !fixtureRoot) throw new Error("Preview fixture paths are required.");
  await writeFile(path.join(fixtureRoot, "PreviewSelfCaptureProbe.swift"), helperSource, "utf8");
  await writeFile(path.join(fixtureRoot, "TestView.swift"), previewSource, "utf8");
  await writeFile(path.join(outputDirectory, "PreviewSelfCaptureProbe.swift"), helperSource, "utf8");
  await writeFile(path.join(outputDirectory, "TestView.swift"), previewSource, "utf8");

  await client.connect(transport, { timeout: 180_000 });
  connected = true;
  const opened = await call(client, "XcodeOpenWorkspace", { path: projectPath }, 180_000);
  const workspaceIdentifier = opened.workspaceIdentifier ?? projectPath;
  const rendered = await call(client, "RenderPreview", {
    workspaceIdentifier,
    sourceFilePath,
    previewDefinitionIndexInFile: 0,
    timeout: 300,
  }, 360_000);
  results.rendered = rendered;
  const snapshotPath = findSnapshotPath(rendered);
  if (!snapshotPath) throw new Error("RenderPreview did not return a snapshot path.");
  const copiedSnapshot = path.join(outputDirectory, "render-preview.png");
  await copyFile(snapshotPath, copiedSnapshot);
  results.renderSnapshot = await fileFacts(copiedSnapshot);

  const listJson = await runXcrun(["simctl", "--set", "previews", "list", "devices", "--json"]);
  const booted = findBootedDevice(listJson.stdout);
  results.bootedPreviewDevice = booted;
  if (!booted) throw new Error("No Booted device exists in the Previews device set.");

  const enumerate = await runXcrun(["simctl", "--set", "previews", "io", booted.udid, "enumerate"]);
  results.simctlEnumerate = enumerate;
  await writeFile(path.join(outputDirectory, "simctl-io-enumerate.txt"), `${enumerate.stdout}${enumerate.stderr}`, "utf8");

  const applicationDataRoot = path.join(booted.dataPath, "Containers", "Data", "Application");
  let captureDirectories = [];
  for (let attempt = 0; attempt < 20; attempt += 1) {
    captureDirectories = await locateCaptureDirectories(applicationDataRoot);
    if (captureDirectories.length > 0) break;
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  results.captureDirectories = captureDirectories;

  const captureOutput = path.join(outputDirectory, "self-capture");
  await mkdir(captureOutput, { recursive: true });
  const collected = [];
  for (const directory of captureDirectories) {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isFile() || (!entry.name.endsWith(".png") && entry.name !== "manifest.json")) continue;
      const destination = path.join(captureOutput, entry.name);
      await copyFile(path.join(directory, entry.name), destination);
      collected.push(destination);
    }
  }

  const frames = (await Promise.all(collected.filter((item) => item.endsWith(".png")).map(fileFacts)))
    .sort((a, b) => a.name.localeCompare(b.name));
  results.selfCaptureFrames = frames;
  results.uniqueSelfCaptureFrames = new Set(frames.map((frame) => frame.sha256)).size;
  const manifestPath = collected.find((item) => item.endsWith("manifest.json"));
  if (manifestPath) results.selfCaptureManifest = JSON.parse(await readFile(manifestPath, "utf8"));

  if (frames.length === 0) results.verdict = "SELF_CAPTURE_PRODUCED_NO_FRAMES";
  else if (results.uniqueSelfCaptureFrames < 2) results.verdict = "SELF_CAPTURE_STATIC";
  else results.verdict = "SELF_CAPTURE_LIVE_FRAMES_CHANGED";
} catch (error) {
  results.verdict = "TEST_FAILED";
  results.error = error instanceof Error ? error.stack ?? error.message : String(error);
  process.exitCode = 1;
} finally {
  results.finishedAt = new Date().toISOString();
  await writeFile(path.join(outputDirectory, "results.json"), JSON.stringify(results, null, 2), "utf8");
  await writeFile(path.join(outputDirectory, "report.md"), [
    "# Xcode Preview runtime self-capture test",
    "",
    `**Verdict:** \`${results.verdict}\``,
    "",
    `simctl enumerate succeeded: ${results.simctlEnumerate?.ok ?? false}`,
    "",
    `Self-captured PNG frames: ${results.selfCaptureFrames?.length ?? 0}`,
    "",
    `Unique self-captured frames: ${results.uniqueSelfCaptureFrames ?? 0}`,
    "",
    `Connected UIWindowScene count: ${results.selfCaptureManifest?.connectedSceneCount ?? "unknown"}`,
    "",
    results.error ? `## Error\n\n\`\`\`text\n${results.error}\n\`\`\`` : "",
  ].join("\n"), "utf8");
  if (connected) await client.close();
}
