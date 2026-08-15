import { spawn } from "node:child_process";
import { copyFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const outputDirectory = path.resolve(process.argv[2] ?? "recordvideo-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const fixturePath = path.resolve(process.env.PREVIEW_SOURCE_PATH ?? "");
const sourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const fixtureRoot = path.resolve(".github/xcode-headless-preview/recordvideo-fixture");
const results = { startedAt: new Date().toISOString(), progressiveDecode: [], screenEnumerations: [] };
await mkdir(outputDirectory, { recursive: true });

function decode(result) { if (result?.structuredContent) return result.structuredContent; const text = result?.content?.filter((i) => i.type === "text").map((i) => i.text).join("\n"); try { return JSON.parse(text); } catch { return { text }; } }
async function call(client, name, args, timeout) { const raw = await client.request({ method: "tools/call", params: { name, arguments: args } }, CompatibilityCallToolResultSchema, { timeout, resetTimeoutOnProgress: true }); const value = decode(raw); if (raw.isError) throw new Error(`${name}: ${JSON.stringify(value)}`); return value; }
function exec(command, args) { return new Promise((resolve) => { const child = spawn(command, args, { env: process.env }); let stdout = ""; let stderr = ""; child.stdout.on("data", (c) => stdout += c); child.stderr.on("data", (c) => stderr += c); child.on("close", (code, signal) => resolve({ command, args, code, signal, stdout, stderr })); }); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
async function stopRecording(child, stdout, stderr) {
  const closed = new Promise((resolve) => child.once("close", (code, signal) => resolve({ code, signal, stdout, stderr })));
  child.kill("SIGINT");
  const graceful = await Promise.race([closed, sleep(10_000).then(() => null)]);
  if (graceful) return graceful;
  child.kill("SIGKILL");
  return await Promise.race([closed, sleep(3_000).then(() => ({ code: null, signal: "recordVideo did not exit after SIGKILL", stdout, stderr }))]);
}
function sceneScreens(output) {
  const blocks = output.split(/\n\s{4}\(/).map((block) => `    (${block}`);
  return blocks.flatMap((block) => {
    if (!/Screen Type: Scene/.test(block)) return [];
    const id = block.match(/Screen ID: (\d+)/)?.[1]; const size = block.match(/Pixel Size: \{(\d+), (\d+)\}/);
    return id ? [{ id, width: Number(size?.[1] ?? 0), height: Number(size?.[2] ?? 0) }] : [];
  });
}
async function enumerate(udid, label) { const value = await exec("xcrun", ["simctl", "--set", "previews", "io", udid, "enumerate"]); const entry = { label, at: new Date().toISOString(), code: value.code, screens: sceneScreens(value.stdout), stderr: value.stderr }; results.screenEnumerations.push(entry); return entry; }
async function progressiveProbe(videoPath) {
  const probe = await exec("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "json", videoPath]);
  let bytes = 0; try { bytes = (await stat(videoPath)).size; } catch {}
  results.progressiveDecode.push({ at: new Date().toISOString(), bytes, readable: probe.code === 0, stderr: probe.stderr, stdout: probe.stdout });
}

let client; let recording;
try {
  if (!projectPath || !fixturePath) throw new Error("Preview fixture paths are required.");
  const before = path.join(fixtureRoot, "Before.swift"); const after = path.join(fixtureRoot, "After.swift");
  await copyFile(before, fixturePath); await copyFile(before, path.join(outputDirectory, "Before.swift")); await copyFile(after, path.join(outputDirectory, "After.swift"));
  const transport = new StdioClientTransport({ command: "xcrun", args: ["mcpbridge"], env: { ...process.env }, stderr: "pipe" });
  client = new Client({ name: "preview-simctl-recordvideo-test", version: "1.0.0" }); await client.connect(transport, { timeout: 180_000 });
  const opened = await call(client, "XcodeOpenWorkspace", { path: projectPath }, 180_000);
  const workspaceIdentifier = opened.workspaceIdentifier ?? projectPath;
  results.beforeRender = await call(client, "RenderPreview", { workspaceIdentifier, sourceFilePath, previewDefinitionIndexInFile: 0, timeout: 600 }, 660_000);
  const devices = await exec("xcrun", ["simctl", "--set", "previews", "list", "devices"]);
  const udid = devices.stdout.match(/\(([0-9A-F-]{36})\) \(Booted\)/i)?.[1]; if (!udid) throw new Error(`No booted Preview device: ${devices.stdout}`);
  results.previewDeviceUDID = udid; results.simctlHelp = await exec("xcrun", ["simctl", "--set", "previews", "io", udid, "help"]);
  const initial = await enumerate(udid, "before-recording");
  const target = initial.screens.find((screen) => screen.id === "136") ?? initial.screens.find((screen) => screen.height > 1000);
  if (!target) throw new Error(`No Preview Scene screen found: ${JSON.stringify(initial)}`);
  results.targetScreen = target;
  const videoPath = path.join(outputDirectory, "preview-live-change.mov");
  recording = spawn("xcrun", ["simctl", "--set", "previews", "io", udid, "recordVideo", "--codec=h264", `--display=${target.id}`, "--force", videoPath], { env: process.env });
  let recordStdout = ""; let recordStderr = ""; recording.stdout.on("data", (c) => recordStdout += c); recording.stderr.on("data", (c) => recordStderr += c);
  await sleep(4000); await progressiveProbe(videoPath); await enumerate(udid, "recording-before-swift-change");
  await copyFile(after, fixturePath); await sleep(500);
  // A recording must never leave the job waiting indefinitely for a Preview
  // refresh.  Observe the request for one minute, then close and analyse the
  // video even if the Preview service is still blocked.
  let afterRenderSettled = false;
  const afterRenderPromise = call(client, "RenderPreview", { workspaceIdentifier, sourceFilePath, previewDefinitionIndexInFile: 0, timeout: 600 }, 660_000)
    .then((value) => { afterRenderSettled = true; return { status: "completed", value }; })
    .catch((error) => { afterRenderSettled = true; return { status: "failed", error: error instanceof Error ? error.message : String(error) }; });
  for (let i = 0; i < 6; i += 1) { await sleep(3000); await progressiveProbe(videoPath); await enumerate(udid, `recording-update-poll-${i + 1}`); }
  results.afterRender = await Promise.race([
    afterRenderPromise,
    sleep(42_000).then(() => ({ status: "pending-after-60-second-observation" })),
  ]);
  await sleep(5000); await progressiveProbe(videoPath); await enumerate(udid, "recording-after-preview-update");
  results.recording = await stopRecording(recording, recordStdout, recordStderr);
  results.finalProbe = await exec("ffprobe", ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=width,height,avg_frame_rate,r_frame_rate,nb_read_frames,duration", "-of", "json", videoPath]);
  results.beforeFrame = await exec("ffmpeg", ["-y", "-ss", "1", "-i", videoPath, "-frames:v", "1", path.join(outputDirectory, "before-update.png")]);
  results.afterFrame = await exec("ffmpeg", ["-y", "-sseof", "-2", "-i", videoPath, "-frames:v", "1", path.join(outputDirectory, "after-update.png")]);
  results.verdict = "RECORDVIDEO_CHANGE_TEST_COMPLETED";
} catch (error) {
  results.verdict = "TEST_FAILED"; results.error = error instanceof Error ? error.stack ?? error.message : String(error); process.exitCode = 1;
} finally {
  if (recording && recording.exitCode === null) recording.kill("SIGKILL");
  results.finishedAt = new Date().toISOString(); await writeFile(path.join(outputDirectory, "test-results.json"), JSON.stringify(results, null, 2), "utf8");
  if (client) await Promise.race([client.close(), sleep(10_000)]);
}
