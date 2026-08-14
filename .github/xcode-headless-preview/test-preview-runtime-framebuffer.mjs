import { createHash } from "node:crypto";
import { execFile as execFileCallback, spawn } from "node:child_process";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const execFile = promisify(execFileCallback);
const outputDirectory = path.resolve(process.argv[2] ?? "preview-runtime-framebuffer-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const sourcePath = path.resolve(process.env.PREVIEW_SOURCE_PATH ?? "");
const sourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const results = { startedAt: new Date().toISOString() };

await mkdir(outputDirectory, { recursive: true });

const liveSource = `import SwiftUI

struct TestView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 20) {
                    Text("Xcode Live Preview")
                        .font(.title)

                    Text(context.date.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 40, weight: .bold, design: .monospaced))

                    Circle()
                        .trim(from: 0, to: (context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 10) + 1) / 10)
                        .stroke(.cyan, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 120, height: 120)
                }
                .foregroundStyle(.white)
            }
        }
    }
}

#Preview("Live framebuffer test") {
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

async function runXcrun(args, options = {}) {
  try {
    const { stdout = "", stderr = "" } = await execFile("xcrun", args, {
      maxBuffer: 20 * 1024 * 1024,
      ...options,
    });
    return { ok: true, stdout, stderr };
  } catch (error) {
    return {
      ok: false,
      stdout: error.stdout ?? "",
      stderr: error.stderr ?? "",
      error: error.message,
      code: error.code,
    };
  }
}

function findSnapshotPath(result) {
  if (typeof result?.previewSnapshotPath === "string") return result.previewSnapshotPath;
  return JSON.stringify(result).match(/(?:\/[^"\\]+\.png)/i)?.[0];
}

function findBootedDevices(jsonText) {
  try {
    const parsed = JSON.parse(jsonText);
    return Object.entries(parsed.devices ?? {}).flatMap(([runtime, devices]) =>
      devices.filter((device) => device.state === "Booted").map((device) => ({ runtime, ...device })),
    );
  } catch (error) {
    results.deviceListJsonParseError = String(error);
    return [];
  }
}

async function fileFacts(filePath) {
  const bytes = await readFile(filePath);
  return { bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") };
}

async function recordVideo(udid, outputPath) {
  return await new Promise((resolve) => {
    const child = spawn("xcrun", ["simctl", "--set", "previews", "io", udid, "recordVideo", "--codec=h264", outputPath], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const stop = setTimeout(() => child.kill("SIGINT"), 5_000);
    const force = setTimeout(() => child.kill("SIGTERM"), 12_000);
    child.on("error", (error) => {
      clearTimeout(stop);
      clearTimeout(force);
      resolve({ ok: false, error: error.message, stdout, stderr });
    });
    child.on("close", (code, signal) => {
      clearTimeout(stop);
      clearTimeout(force);
      resolve({ ok: code === 0 || signal === "SIGINT", code, signal, stdout, stderr });
    });
  });
}

const transport = new StdioClientTransport({
  command: "xcrun",
  args: ["mcpbridge"],
  env: { ...process.env },
  stderr: "pipe",
});
transport.stderr?.on("data", (chunk) => process.stderr.write(chunk));
const client = new Client({ name: "preview-runtime-framebuffer-test", version: "1.0.0" });
let connected = false;

try {
  if (!projectPath || !sourcePath) throw new Error("PREVIEW_PROJECT_PATH and PREVIEW_SOURCE_PATH are required.");
  await writeFile(sourcePath, liveSource, "utf8");
  await writeFile(path.join(outputDirectory, "LiveTest.swift"), liveSource, "utf8");

  await client.connect(transport, { timeout: 180_000 });
  connected = true;
  const { tools } = await client.listTools(undefined, { timeout: 180_000 });
  results.tools = tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema }));

  const opened = await call(client, "XcodeOpenWorkspace", { path: projectPath });
  const workspaceIdentifier = opened.workspaceIdentifier ?? projectPath;
  const rendered = await call(client, "RenderPreview", {
    workspaceIdentifier,
    sourceFilePath,
    previewDefinitionIndexInFile: 0,
    timeout: 240,
  }, 300_000);
  results.renderCompletedAt = new Date().toISOString();
  const snapshotPath = findSnapshotPath(rendered);
  if (snapshotPath) await copyFile(snapshotPath, path.join(outputDirectory, "render-preview-start.png"));

  // The experiment deliberately makes no second RenderPreview call after this point.
  const listText = await runXcrun(["simctl", "--set", "previews", "list", "devices"]);
  const listJson = await runXcrun(["simctl", "--set", "previews", "list", "devices", "--json"]);
  await writeFile(path.join(outputDirectory, "preview-devices.txt"), `${listText.stdout}${listText.stderr}`, "utf8");
  await writeFile(path.join(outputDirectory, "preview-devices.json"), listJson.stdout || JSON.stringify(listJson, null, 2), "utf8");
  results.deviceList = { text: listText, json: listJson };

  const ioHelp = await runXcrun(["simctl", "--set", "previews", "help", "io"]);
  await writeFile(path.join(outputDirectory, "simctl-io-help.txt"), `${ioHelp.stdout}${ioHelp.stderr}`, "utf8");
  results.ioHelp = ioHelp;

  let booted = findBootedDevices(listJson.stdout);
  if (booted.length === 0) {
    const matches = listText.stdout.matchAll(/\(([0-9A-Fa-f-]{36})\) \(Booted\)/g);
    booted = [...matches].map((match) => ({ udid: match[1], name: "unknown", runtime: "text-list" }));
  }
  results.bootedDevices = booted;

  if (booted.length === 0) {
    results.verdict = "NO_BOOTED_PREVIEW_DEVICE";
  } else {
    const udid = booted[0].udid;
    const firstPath = path.join(outputDirectory, "live1.png");
    const secondPath = path.join(outputDirectory, "live2.png");
    const thirdPath = path.join(outputDirectory, "live3.png");
    const captures = [];
    captures.push(await runXcrun(["simctl", "--set", "previews", "io", udid, "screenshot", firstPath]));
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    captures.push(await runXcrun(["simctl", "--set", "previews", "io", udid, "screenshot", secondPath]));
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    captures.push(await runXcrun(["simctl", "--set", "previews", "io", udid, "screenshot", thirdPath]));
    results.screenshotCommands = captures;

    if (captures.every((capture) => capture.ok)) {
      const facts = await Promise.all([firstPath, secondPath, thirdPath].map(fileFacts));
      results.frames = facts;
      results.framesDiffer = new Set(facts.map((fact) => fact.sha256)).size > 1;
      results.verdict = results.framesDiffer ? "LIVE_FRAMEBUFFER_CHANGES" : "BOOTED_BUT_FRAMEBUFFER_STATIC";

      const videoPath = path.join(outputDirectory, "preview-runtime-5s.mov");
      results.recordVideo = await recordVideo(udid, videoPath);
      try { results.video = await fileFacts(videoPath); } catch (error) { results.videoFileError = String(error); }
    } else {
      results.verdict = "BOOTED_DEVICE_SCREENSHOT_FAILED";
    }
  }
} catch (error) {
  results.verdict = "TEST_SETUP_FAILED";
  results.error = error instanceof Error ? error.stack ?? error.message : String(error);
  process.exitCode = 1;
} finally {
  results.finishedAt = new Date().toISOString();
  const report = [
    "# Xcode Preview runtime framebuffer test",
    "",
    `**Verdict:** \`${results.verdict}\``,
    "",
    "Only one `RenderPreview` call was made. All `live*.png` captures, when present, came directly from `simctl --set previews io` afterward.",
    "",
    `Booted Preview devices: ${results.bootedDevices?.length ?? 0}`,
    "",
    `Frames differ without another render: ${results.framesDiffer ?? "not tested"}`,
    "",
    `recordVideo result: ${results.recordVideo ? JSON.stringify(results.recordVideo) : "not tested"}`,
    "",
    results.error ? `## Error\n\n\`\`\`text\n${results.error}\n\`\`\`\n` : "",
  ].join("\n");
  await writeFile(path.join(outputDirectory, "report.md"), report, "utf8");
  await writeFile(path.join(outputDirectory, "results.json"), JSON.stringify(results, null, 2), "utf8");
  if (connected) await client.close();
}
