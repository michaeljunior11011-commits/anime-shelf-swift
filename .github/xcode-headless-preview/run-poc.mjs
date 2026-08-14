import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const outputDirectory = path.resolve(process.argv[2] ?? "xcode-preview-output");
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const sourcePath = path.resolve(process.env.PREVIEW_SOURCE_PATH ?? "");
const sourceFilePath = process.env.PREVIEW_SOURCE_FILE ?? "PreviewLab/TestView.swift";
const mode = process.env.XCODE_MCP_MODE ?? "xcode";
const reportPath = path.join(outputDirectory, "report.md");
const toolLogPath = path.join(outputDirectory, "tool-results.json");
const results = { mode };

await mkdir(outputDirectory, { recursive: true });

const transport = new StdioClientTransport({
  command: "xcrun",
  args: ["mcpbridge"],
  env: { ...process.env },
  stderr: "pipe",
});

transport.stderr?.on("data", (chunk) => {
  process.stderr.write(chunk);
});

const client = new Client({ name: "xcode-preview-poc", version: "2.0.0" });

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
  results[name] ??= [];
  results[name].push({ arguments: args, result: decoded });
  if (raw?.isError) throw new Error(`${name} failed: ${JSON.stringify(decoded)}`);
  return decoded;
}

function findSnapshotPath(result) {
  if (typeof result?.previewSnapshotPath === "string") return result.previewSnapshotPath;
  const candidate = JSON.stringify(result).match(/(?:\/[^"]+\.png)/i);
  return candidate?.[0];
}

function previewSource(letter) {
  return `import SwiftUI

struct TestView: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.12)
                .ignoresSafeArea()

            Text("${letter}")
                .font(.system(size: 120, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

#Preview("Proof ${letter}") {
    TestView()
}
`;
}

function tabIdentifierFrom(result) {
  const text = result?.message ?? result?.text ?? JSON.stringify(result);
  return text.match(/tabIdentifier:\s*([^,\s]+)/)?.[1];
}

function permissionHint(error) {
  const message = String(error).toLowerCase();
  if (mode === "xcode" && (message.includes("timeout") || message.includes("timed out"))) {
    return "The Beta 4 bridge timed out while connecting. This normally means Xcode is waiting for a person to approve the external agent.";
  }
  return "The Xcode MCP bridge returned an error before both previews completed.";
}

let connected = false;
try {
  if (!projectPath || !sourcePath) throw new Error("PREVIEW_PROJECT_PATH and PREVIEW_SOURCE_PATH are required.");

  await client.connect(transport, { timeout: 30_000 });
  connected = true;

  const { tools } = await client.listTools(undefined, { timeout: 30_000 });
  results.tools = tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema }));

  if (!tools.some((tool) => tool.name === "RenderPreview")) {
    throw new Error("RenderPreview is not present in tools/list.");
  }

  let targetIdentifier;
  let targetKey;
  if (mode === "headless") {
    if (!tools.some((tool) => tool.name === "XcodeOpenWorkspace")) {
      throw new Error("The headless server did not expose XcodeOpenWorkspace.");
    }
    const opened = await call("XcodeOpenWorkspace", { path: projectPath });
    targetIdentifier = opened.workspaceIdentifier ?? projectPath;
    targetKey = "workspaceIdentifier";
  } else {
    if (!tools.some((tool) => tool.name === "XcodeListWindows")) {
      throw new Error("The Xcode-backed bridge did not expose XcodeListWindows.");
    }
    const windows = await call("XcodeListWindows", {}, 30_000);
    targetIdentifier = tabIdentifierFrom(windows);
    if (!targetIdentifier) {
      throw new Error(`Could not find tabIdentifier in XcodeListWindows: ${JSON.stringify(windows)}`);
    }
    targetKey = "tabIdentifier";
  }

  await writeFile(sourcePath, previewSource("A"), "utf8");
  const firstPreview = await call(
    "RenderPreview",
    { [targetKey]: targetIdentifier, sourceFilePath, previewDefinitionIndexInFile: 0, timeout: 180 },
    240_000,
  );
  const firstSnapshot = findSnapshotPath(firstPreview);
  if (!firstSnapshot) throw new Error(`First RenderPreview did not return a PNG path: ${JSON.stringify(firstPreview)}`);
  await copyFile(firstSnapshot, path.join(outputDirectory, "preview-A.png"));

  await writeFile(sourcePath, previewSource("B"), "utf8");
  const secondPreview = await call(
    "RenderPreview",
    { [targetKey]: targetIdentifier, sourceFilePath, previewDefinitionIndexInFile: 0, timeout: 180 },
    240_000,
  );
  const secondSnapshot = findSnapshotPath(secondPreview);
  if (!secondSnapshot) throw new Error(`Second RenderPreview did not return a PNG path: ${JSON.stringify(secondPreview)}`);
  await copyFile(secondSnapshot, path.join(outputDirectory, "preview-B.png"));

  const firstBytes = await readFile(path.join(outputDirectory, "preview-A.png"));
  const secondBytes = await readFile(path.join(outputDirectory, "preview-B.png"));
  if (firstBytes.equals(secondBytes)) throw new Error("The A and B preview PNG files are identical.");

  await writeFile(
    reportPath,
    [
      "# Xcode SwiftUI preview proof",
      "",
      `✅ Connected through the ${mode === "headless" ? "Beta 5 headless server" : "Beta 4 hidden-Xcode bridge"}.`,
      "",
      "✅ `tools/list` contains `RenderPreview`.",
      "",
      "✅ `RenderPreview` produced `preview-A.png` and `preview-B.png`.",
      "",
      "✅ The PNG files differ after changing the SwiftUI source from A to B.",
      "",
    ].join("\n"),
    "utf8",
  );
} catch (error) {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  results.error = message;
  await writeFile(
    reportPath,
    [
      "# Xcode SwiftUI preview proof",
      "",
      "❌ The proof did not complete.",
      "",
      permissionHint(message),
      "",
      "```text",
      message,
      "```",
      "",
    ].join("\n"),
    "utf8",
  );
  process.exitCode = 1;
} finally {
  await writeFile(toolLogPath, JSON.stringify(results, null, 2), "utf8");
  if (connected) await client.close();
}
