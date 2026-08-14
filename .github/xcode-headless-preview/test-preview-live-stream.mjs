import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const outputDirectory = path.resolve(process.argv[2] ?? "live-preview-stream-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const fixtureRoot = path.dirname(path.resolve(process.env.PREVIEW_SOURCE_PATH ?? ""));
const sourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const sourceRoot = path.resolve(".github/xcode-headless-preview/streaming-fixture");
const results = { startedAt: new Date().toISOString() };
await mkdir(outputDirectory, { recursive: true });

function decodedResult(result) {
  if (result?.structuredContent) return result.structuredContent;
  const text = result?.content?.filter((item) => item.type === "text").map((item) => item.text).join("\n");
  if (!text) return result;
  try { return JSON.parse(text); } catch { return { text }; }
}

async function call(client, name, args, timeout) {
  const raw = await client.request({ method: "tools/call", params: { name, arguments: args } }, CompatibilityCallToolResultSchema, { timeout, resetTimeoutOnProgress: true });
  const decoded = decodedResult(raw);
  results.mcpCalls ??= []; results.mcpCalls.push({ name, arguments: args, result: decoded });
  if (raw?.isError) throw new Error(`${name} failed: ${JSON.stringify(decoded)}`);
  return decoded;
}

async function waitForJSON(url, predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs; let last;
  while (Date.now() < deadline) {
    try { last = await fetch(url, { cache: "no-store" }).then((response) => response.json()); if (predicate(last)) return last; } catch {}
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Timed out waiting for ${url}. Last response: ${JSON.stringify(last)}`);
}

let receiver;
let client;
try {
  if (!projectPath || !fixtureRoot) throw new Error("Preview fixture paths are required.");
  const helperSource = await readFile(path.join(sourceRoot, "PreviewLiveStreamProbe.swift"), "utf8");
  const previewSource = await readFile(path.join(sourceRoot, "TestView.swift"), "utf8");
  await writeFile(path.join(fixtureRoot, "PreviewLiveStreamProbe.swift"), helperSource, "utf8");
  await writeFile(path.join(fixtureRoot, "TestView.swift"), previewSource, "utf8");
  await writeFile(path.join(outputDirectory, "PreviewLiveStreamProbe.swift"), helperSource, "utf8");
  await writeFile(path.join(outputDirectory, "TestView.swift"), previewSource, "utf8");

  receiver = spawn(process.execPath, [path.resolve(".github/xcode-headless-preview/live-preview-receiver.mjs"), outputDirectory], { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env } });
  let receiverLog = "";
  receiver.stdout.on("data", (chunk) => { receiverLog += chunk; process.stdout.write(chunk); });
  receiver.stderr.on("data", (chunk) => { receiverLog += chunk; process.stderr.write(chunk); });
  await waitForJSON("http://127.0.0.1:8080/health", (value) => value.ok, 20_000);

  const transport = new StdioClientTransport({ command: "xcrun", args: ["mcpbridge"], env: { ...process.env }, stderr: "pipe" });
  transport.stderr?.on("data", (chunk) => process.stderr.write(chunk));
  client = new Client({ name: "preview-live-stream-backpressure-test", version: "2.0.0" });
  await client.connect(transport, { timeout: 180_000 });
  const opened = await call(client, "XcodeOpenWorkspace", { path: projectPath }, 180_000);
  const workspaceIdentifier = opened.workspaceIdentifier ?? projectPath;
  results.renderResult = await call(client, "RenderPreview", { workspaceIdentifier, sourceFilePath, previewDefinitionIndexInFile: 0, timeout: 420 }, 480_000);

  results.receiverStats = await waitForJSON("http://127.0.0.1:8080/stats", (value) => value.complete, 180_000);
  results.viewerHTMLServed = (await fetch("http://127.0.0.1:8080/")).ok;
  results.verdict = results.receiverStats.phases.length === 3 && results.receiverStats.phases.every((phase) => phase.receivedFrames > 10 && phase.uniqueFrames > 5)
    ? "LIVE_JPEG_BACKPRESSURE_STREAM_CONFIRMED" : "STREAM_PHASES_INCOMPLETE";
  results.performanceVerdict = results.receiverStats.phases.map((phase) => ({
    targetFPS: phase.targetFPS,
    stable: phase.actualFPS >= phase.targetFPS * 0.7 && phase.sendTimeouts <= Math.max(2, phase.receivedFrames * 0.05),
  }));
  await writeFile(path.join(outputDirectory, "receiver.log"), receiverLog, "utf8");
} catch (error) {
  results.verdict = "TEST_FAILED"; results.error = error instanceof Error ? error.stack ?? error.message : String(error); process.exitCode = 1;
} finally {
  results.finishedAt = new Date().toISOString();
  await writeFile(path.join(outputDirectory, "test-results.json"), JSON.stringify(results, null, 2), "utf8");
  if (client) await client.close();
  if (receiver && !receiver.killed) receiver.kill("SIGTERM");
}
