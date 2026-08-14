import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import process from "node:process";
import { performance } from "node:perf_hooks";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const outputDirectory = path.resolve(process.argv[2] ?? "xcode-warm-benchmark-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const existingSourcePath = path.resolve(process.env.PREVIEW_SOURCE_PATH ?? "");
const existingSourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const newSourceFilePath = "PreviewLab/Swift2000.swift";
const reportPath = path.join(outputDirectory, "warm-benchmark.md");
const jsonPath = path.join(outputDirectory, "warm-benchmark.json");
const csvPath = path.join(outputDirectory, "warm-benchmark.csv");

const results = {
  startedAt: new Date().toISOString(),
  projectPath,
  workspaceIdentifier: null,
  newFileCreationMs: null,
  samples: [],
};

await mkdir(outputDirectory, { recursive: true });

const transport = new StdioClientTransport({
  command: "xcrun",
  args: ["mcpbridge"],
  env: { ...process.env },
  stderr: "pipe",
});

transport.stderr?.on("data", (chunk) => process.stderr.write(chunk));

const client = new Client({ name: "xcode-warm-preview-benchmark", version: "1.0.0" });

function decodedResult(result) {
  if (result?.structuredContent) return result.structuredContent;
  const text = result?.content
    ?.filter((item) => item.type === "text")
    .map((item) => item.text)
    .join("\n");
  if (!text) return result;
  try {
    return JSON.parse(text);
  } catch {
    return { text };
  }
}

async function call(name, args, timeout = 60_000) {
  const raw = await client.request(
    { method: "tools/call", params: { name, arguments: args } },
    CompatibilityCallToolResultSchema,
    { timeout, resetTimeoutOnProgress: true },
  );
  const decoded = decodedResult(raw);
  if (raw?.isError) throw new Error(`${name} failed: ${JSON.stringify(decoded)}`);
  return decoded;
}

function findSnapshotPath(result) {
  if (typeof result?.previewSnapshotPath === "string") return result.previewSnapshotPath;
  const candidate = JSON.stringify(result).match(/(?:\/[^\"]+\.png)/i);
  return candidate?.[0];
}

function existingSource(text) {
  return `import SwiftUI

struct TestView: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.12)
                .ignoresSafeArea()

            Text("${text}")
                .font(.system(size: 96, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

#Preview("Warm benchmark ${text}") {
    TestView()
}
`;
}

function swift2000Source(text) {
  return `import SwiftUI

struct Swift2000: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.08, blue: 0.16)
                .ignoresSafeArea()

            Text("${text}")
                .font(.largeTitle.bold())
                .foregroundStyle(.cyan)
        }
    }
}

#Preview("Swift 2000") {
    Swift2000()
}
`;
}

function elapsedMs(started) {
  return Math.round((performance.now() - started) * 10) / 10;
}

async function saveDirectly(filePath, content) {
  const started = performance.now();
  await writeFile(filePath, content, "utf8");
  return elapsedMs(started);
}

async function saveThroughXcode(filePath, content) {
  const started = performance.now();
  await call(
    "XcodeWrite",
    { workspaceIdentifier: results.workspaceIdentifier, filePath, content },
    60_000,
  );
  return elapsedMs(started);
}

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function render({ phase, label, sourceFilePath, writeMs }) {
  const isCold = phase === "cold";
  const timeoutSeconds = isCold ? 240 : 60;
  const maxAttempts = isCold ? 1 : 2;
  const allAttemptsStarted = performance.now();
  const attempts = [];
  let response;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const attemptStarted = performance.now();
    try {
      response = await call(
        "RenderPreview",
        {
          workspaceIdentifier: results.workspaceIdentifier,
          sourceFilePath,
          previewDefinitionIndexInFile: 0,
          timeout: timeoutSeconds,
        },
        (timeoutSeconds + 30) * 1000,
      );
      attempts.push({ attempt, status: "success", durationMs: elapsedMs(attemptStarted) });
      break;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      attempts.push({ attempt, status: "failed", durationMs: elapsedMs(attemptStarted), error: message });
      console.log(`BENCHMARK ${label} attempt ${attempt} failed after ${attempts.at(-1).durationMs.toFixed(1)}ms`);
      if (attempt < maxAttempts) await wait(3_000);
    }
  }

  const successfulAttempt = attempts.find((attempt) => attempt.status === "success");
  if (!successfulAttempt) {
    const sample = {
      phase,
      label,
      writeMs,
      renderMs: null,
      totalMs: Math.round((writeMs + elapsedMs(allAttemptsStarted)) * 10) / 10,
      imageName: null,
      bytes: null,
      sha256: null,
      changedFromPrevious: null,
      attempts,
      error: attempts.at(-1)?.error ?? "RenderPreview failed without an error message.",
    };
    results.samples.push(sample);
    return sample;
  }

  const renderMs = successfulAttempt.durationMs;
  const snapshotPath = findSnapshotPath(response);
  if (!snapshotPath) throw new Error(`${label} did not return a previewSnapshotPath: ${JSON.stringify(response)}`);

  const imageName = `${String(results.samples.length).padStart(2, "0")}-${label}.png`;
  const destination = path.join(outputDirectory, imageName);
  await copyFile(snapshotPath, destination);
  const bytes = await readFile(destination);
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const previous = [...results.samples].reverse().find((sample) => sample.sha256);
  const changedFromPrevious = previous ? previous.sha256 !== sha256 : null;

  const sample = {
    phase,
    label,
    writeMs,
    renderMs,
    totalMs: Math.round((writeMs + elapsedMs(allAttemptsStarted)) * 10) / 10,
    imageName,
    bytes: bytes.length,
    sha256,
    changedFromPrevious,
    attempts,
  };
  if (previous && !changedFromPrevious) sample.error = `${label} produced the same PNG bytes as ${previous.label}.`;
  results.samples.push(sample);
  console.log(`BENCHMARK ${label}: write=${writeMs.toFixed(1)}ms render=${renderMs.toFixed(1)}ms attempts=${attempts.length} total=${sample.totalMs.toFixed(1)}ms`);
  return sample;
}

function summarize(samples) {
  const values = samples.map((sample) => sample.renderMs).filter(Number.isFinite).sort((a, b) => a - b);
  if (!values.length) return null;
  const average = values.reduce((sum, value) => sum + value, 0) / values.length;
  const percentile = (fraction) => values[Math.min(values.length - 1, Math.ceil(values.length * fraction) - 1)];
  return {
    count: values.length,
    minMs: values[0],
    medianMs: percentile(0.5),
    averageMs: Math.round(average * 10) / 10,
    p95Ms: percentile(0.95),
    maxMs: values.at(-1),
  };
}

function reportMarkdown(errorMessage = null) {
  const warm = results.samples.filter((sample) => sample.phase === "existing-warm");
  const newFile = results.samples.filter((sample) => sample.phase === "new-file");
  const lines = [
    "# Xcode 27 Beta 5 warm RenderPreview benchmark",
    "",
    errorMessage ? "Result: FAILED" : "Result: PASSED",
    "",
    "The project, workspace, MCP server, and MCP client stayed alive for every sample.",
    "",
    "| Phase | Sample | Save (ms) | RenderPreview (ms) | Attempts | Total (ms) | PNG changed |",
    "|---|---:|---:|---:|---:|---:|:---:|",
    ...results.samples.map((sample) =>
      `| ${sample.phase} | ${sample.label} | ${sample.writeMs.toFixed(1)} | ${Number.isFinite(sample.renderMs) ? sample.renderMs.toFixed(1) : "FAILED"} | ${sample.attempts.length} | ${sample.totalMs.toFixed(1)} | ${sample.changedFromPrevious === null ? "n/a" : sample.changedFromPrevious ? "yes" : "NO"} |`,
    ),
    "",
  ];

  if (warm.length) {
    const stats = summarize(warm);
    if (stats) lines.push(
      "## Existing TestView warm renders",
      "",
      `Count: ${stats.count}; min: ${stats.minMs.toFixed(1)} ms; median: ${stats.medianMs.toFixed(1)} ms; average: ${stats.averageMs.toFixed(1)} ms; p95: ${stats.p95Ms.toFixed(1)} ms; max: ${stats.maxMs.toFixed(1)} ms.`,
      "",
    );
  }

  if (newFile.length) {
    const stats = summarize(newFile);
    if (stats) lines.push(
      "## Swift2000.swift renders",
      "",
      `Created during the live workspace session with XcodeWrite in ${results.newFileCreationMs?.toFixed(1) ?? "n/a"} ms.`,
      "",
      `Count: ${stats.count}; min: ${stats.minMs.toFixed(1)} ms; median: ${stats.medianMs.toFixed(1)} ms; average: ${stats.averageMs.toFixed(1)} ms; p95: ${stats.p95Ms.toFixed(1)} ms; max: ${stats.maxMs.toFixed(1)} ms.`,
      "",
    );
  }

  if (errorMessage) lines.push("## Error", "", "```text", errorMessage, "```", "");
  return lines.join("\n");
}

function csvText() {
  const header = "phase,label,write_ms,render_ms,attempts,total_ms,image,bytes,sha256,changed_from_previous,error";
  const rows = results.samples.map((sample) => [
    sample.phase,
    sample.label,
    sample.writeMs,
    sample.renderMs ?? "",
    sample.attempts.length,
    sample.totalMs,
    sample.imageName ?? "",
    sample.bytes ?? "",
    sample.sha256 ?? "",
    sample.changedFromPrevious ?? "",
    sample.error ? JSON.stringify(sample.error) : "",
  ].join(","));
  return [header, ...rows, ""].join("\n");
}

let connected = false;
let failure = null;
try {
  if (!projectPath || !existingSourcePath) {
    throw new Error("PREVIEW_PROJECT_PATH and PREVIEW_SOURCE_PATH are required.");
  }

  await client.connect(transport, { timeout: 30_000 });
  connected = true;
  const { tools } = await client.listTools(undefined, { timeout: 30_000 });
  const requiredTools = ["XcodeOpenWorkspace", "XcodeWrite", "RenderPreview"];
  for (const required of requiredTools) {
    if (!tools.some((tool) => tool.name === required)) throw new Error(`${required} is missing from tools/list.`);
  }

  const opened = await call("XcodeOpenWorkspace", { path: projectPath });
  results.workspaceIdentifier = opened.workspaceIdentifier ?? projectPath;

  let writeMs = await saveDirectly(existingSourcePath, existingSource("Warm-up"));
  const cold = await render({ phase: "cold", label: "cold-warmup", sourceFilePath: existingSourceFilePath, writeMs });
  if (cold.error) throw new Error(`Cold preview failed: ${cold.error}`);
  await wait(5_000);

  for (let index = 1; index <= 10; index += 1) {
    writeMs = await saveThroughXcode(existingSourceFilePath, existingSource(String(index)));
    await render({ phase: "existing-warm", label: `warm-${String(index).padStart(2, "0")}`, sourceFilePath: existingSourceFilePath, writeMs });
    await wait(500);
  }

  results.newFileCreationMs = await saveThroughXcode(newSourceFilePath, swift2000Source("Swift 2000"));
  await render({
    phase: "new-file",
    label: "swift2000-initial",
    sourceFilePath: newSourceFilePath,
    writeMs: results.newFileCreationMs,
  });

  for (let index = 1; index <= 5; index += 1) {
    writeMs = await saveThroughXcode(newSourceFilePath, swift2000Source(`Swift 2000 ${index}`));
    await render({ phase: "new-file", label: `swift2000-${String(index).padStart(2, "0")}`, sourceFilePath: newSourceFilePath, writeMs });
    await wait(500);
  }

  const failedSamples = results.samples.filter((sample) => sample.error);
  if (failedSamples.length) {
    throw new Error(`${failedSamples.length} benchmark sample(s) failed after all in-session retries: ${failedSamples.map((sample) => sample.label).join(", ")}`);
  }
} catch (error) {
  failure = error instanceof Error ? error.stack ?? error.message : String(error);
  results.error = failure;
  process.exitCode = 1;
} finally {
  results.finishedAt = new Date().toISOString();
  await writeFile(jsonPath, `${JSON.stringify(results, null, 2)}\n`, "utf8");
  await writeFile(csvPath, csvText(), "utf8");
  await writeFile(reportPath, reportMarkdown(failure), "utf8");
  if (connected) await client.close();
}
