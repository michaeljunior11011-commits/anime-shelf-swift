import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const outputDirectory = path.resolve(process.argv[2] ?? "jpeg-benchmark-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const fixtureRoot = path.dirname(path.resolve(process.env.PREVIEW_SOURCE_PATH ?? ""));
const sourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const sourceRoot = path.resolve(".github/xcode-headless-preview/jpeg-benchmark-fixture");
const results = { startedAt: new Date().toISOString() };
await mkdir(outputDirectory, { recursive: true });

function decode(result) {
  if (result?.structuredContent) return result.structuredContent;
  const text = result?.content?.filter((item) => item.type === "text").map((item) => item.text).join("\n");
  try { return JSON.parse(text); } catch { return { text }; }
}
async function call(client, name, args, timeout) {
  const raw = await client.request({ method: "tools/call", params: { name, arguments: args } }, CompatibilityCallToolResultSchema, { timeout, resetTimeoutOnProgress: true });
  const value = decode(raw); if (raw.isError) throw new Error(`${name}: ${JSON.stringify(value)}`); return value;
}
async function waitForStats(file, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try { return JSON.parse(await readFile(file, "utf8")); } catch {}
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error("Timed out waiting for the JPEG benchmark report.");
}

let receiver; let client;
try {
  if (!projectPath || !fixtureRoot) throw new Error("Preview fixture paths are required.");
  for (const name of ["PreviewJPEGBenchmarkProbe.swift", "TestView.swift"]) {
    const source = await readFile(path.join(sourceRoot, name), "utf8");
    await writeFile(path.join(fixtureRoot, name), source, "utf8");
    await writeFile(path.join(outputDirectory, name), source, "utf8");
  }
  receiver = spawn(process.execPath, [path.resolve(".github/xcode-headless-preview/jpeg-benchmark-receiver.mjs"), outputDirectory], { stdio: ["ignore", "pipe", "pipe"] });
  receiver.stdout.on("data", (chunk) => process.stdout.write(chunk)); receiver.stderr.on("data", (chunk) => process.stderr.write(chunk));
  const transport = new StdioClientTransport({ command: "xcrun", args: ["mcpbridge"], env: { ...process.env }, stderr: "pipe" });
  client = new Client({ name: "preview-jpeg-resolution-benchmark", version: "1.0.0" });
  await client.connect(transport, { timeout: 180_000 });
  const opened = await call(client, "XcodeOpenWorkspace", { path: projectPath }, 180_000);
  results.renderResult = await call(client, "RenderPreview", { workspaceIdentifier: opened.workspaceIdentifier ?? projectPath, sourceFilePath, previewDefinitionIndexInFile: 0, timeout: 600 }, 660_000);
  results.benchmark = await waitForStats(path.join(outputDirectory, "jpeg-benchmark-stats.json"), 180_000);
  results.requiresH264Prototype = results.benchmark.configurations.some((item) => item.encodeAverageMs > 100);
  results.verdict = results.requiresH264Prototype ? "H264_PROTOTYPE_REQUIRED" : "JPEG_BENCHMARK_WITHIN_BUDGET";
} catch (error) {
  results.verdict = "TEST_FAILED"; results.error = error instanceof Error ? error.stack ?? error.message : String(error); process.exitCode = 1;
} finally {
  results.finishedAt = new Date().toISOString();
  await writeFile(path.join(outputDirectory, "test-results.json"), JSON.stringify(results, null, 2), "utf8");
  if (client) await client.close(); if (receiver && !receiver.killed) receiver.kill("SIGTERM");
}
