import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const outputDirectory = path.resolve(process.argv[2] ?? "source-rate-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const fixtureRoot = path.dirname(path.resolve(process.env.PREVIEW_SOURCE_PATH ?? ""));
const sourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const sourceRoot = path.resolve(".github/xcode-headless-preview/source-rate-fixture");
const results = { startedAt: new Date().toISOString(), simctl: {} };
await mkdir(outputDirectory, { recursive: true });

function decode(result) { if (result?.structuredContent) return result.structuredContent; const text = result?.content?.filter((item) => item.type === "text").map((item) => item.text).join("\n"); try { return JSON.parse(text); } catch { return { text }; } }
async function call(client, name, args, timeout) { const raw = await client.request({ method: "tools/call", params: { name, arguments: args } }, CompatibilityCallToolResultSchema, { timeout, resetTimeoutOnProgress: true }); const value = decode(raw); if (raw.isError) throw new Error(`${name}: ${JSON.stringify(value)}`); return value; }
function command(args) { return new Promise((resolve) => { const child = spawn("xcrun", args, { env: process.env }); let stdout = ""; let stderr = ""; child.stdout.on("data", (c) => stdout += c); child.stderr.on("data", (c) => stderr += c); child.on("close", (code) => resolve({ args, code, stdout, stderr })); }); }
async function waitForFile(file, timeoutMs) { const end = Date.now() + timeoutMs; while (Date.now() < end) { try { return JSON.parse(await readFile(file, "utf8")); } catch {} await new Promise((r) => setTimeout(r, 500)); } throw new Error("Timed out waiting for source-rate report."); }

let receiver; let client;
try {
  if (!projectPath || !fixtureRoot) throw new Error("Preview fixture paths are required.");
  for (const name of ["PreviewSourceRateProbe.swift", "TestView.swift"]) { const source = await readFile(path.join(sourceRoot, name), "utf8"); await writeFile(path.join(fixtureRoot, name), source, "utf8"); await writeFile(path.join(outputDirectory, name), source, "utf8"); }
  receiver = spawn(process.execPath, [path.resolve(".github/xcode-headless-preview/source-rate-receiver.mjs"), outputDirectory], { stdio: ["ignore", "pipe", "pipe"] });
  receiver.stdout.on("data", (chunk) => process.stdout.write(chunk)); receiver.stderr.on("data", (chunk) => process.stderr.write(chunk));
  results.simctl.helpIO = await command(["simctl", "--set", "previews", "help", "io"]);
  const transport = new StdioClientTransport({ command: "xcrun", args: ["mcpbridge"], env: { ...process.env }, stderr: "pipe" });
  client = new Client({ name: "preview-source-rate-probe", version: "1.0.0" }); await client.connect(transport, { timeout: 180_000 });
  const opened = await call(client, "XcodeOpenWorkspace", { path: projectPath }, 180_000);
  const render = call(client, "RenderPreview", { workspaceIdentifier: opened.workspaceIdentifier ?? projectPath, sourceFilePath, previewDefinitionIndexInFile: 0, timeout: 600 }, 660_000);
  await new Promise((r) => setTimeout(r, 12_000));
  results.simctl.devices = await command(["simctl", "--set", "previews", "list", "devices"]);
  const booted = results.simctl.devices.stdout.match(/\(([0-9A-F-]{36})\) \(Booted\)/i)?.[1];
  results.simctl.previewDeviceUDID = booted ?? null;
  results.simctl.enumerate = booted
    ? await command(["simctl", "--set", "previews", "io", booted, "enumerate"])
    : { code: null, stdout: "", stderr: "No booted Preview device was found." };
  results.renderResult = await render;
  results.probe = await waitForFile(path.join(outputDirectory, "source-rate-stats.json"), 180_000);
  results.verdict = "SOURCE_RATE_PROBE_COMPLETED";
} catch (error) { results.verdict = "TEST_FAILED"; results.error = error instanceof Error ? error.stack ?? error.message : String(error); process.exitCode = 1; }
finally { results.finishedAt = new Date().toISOString(); await writeFile(path.join(outputDirectory, "test-results.json"), JSON.stringify(results, null, 2), "utf8"); if (client) await client.close(); if (receiver && !receiver.killed) receiver.kill("SIGTERM"); }
