import { mkdir, copyFile, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const outputDirectory = path.resolve(process.argv[2] ?? "xcode-headless-preview-output");
const projectParent = path.join(outputDirectory, "workspace");
const reportPath = path.join(outputDirectory, "report.md");
const toolLogPath = path.join(outputDirectory, "tool-results.json");
const results = {};

await mkdir(projectParent, { recursive: true });

const transport = new StdioClientTransport({
  command: "xcrun",
  args: ["mcpbridge"],
  env: {
    ...process.env,
    DEVELOPER_DIR: process.env.DEVELOPER_DIR,
  },
  stderr: "inherit",
});

const client = new Client({ name: "xcode-headless-preview-poc", version: "1.0.0" });

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

async function call(name, args) {
  const raw = await client.callTool({ name, arguments: args });
  const decoded = decodedResult(raw);
  results[name] ??= [];
  results[name].push({ arguments: args, result: decoded });
  if (raw?.isError) {
    throw new Error(`${name} failed: ${JSON.stringify(decoded)}`);
  }
  return decoded;
}

function findSnapshotPath(result) {
  if (typeof result?.previewSnapshotPath === "string") return result.previewSnapshotPath;
  if (typeof result?.snapshotPath === "string") return result.snapshotPath;
  const candidate = JSON.stringify(result).match(/(?:\/[^"]+\.png)/i);
  return candidate?.[0];
}

function findProjectPath(result) {
  if (typeof result?.projectPath === "string") return result.projectPath;
  const candidate = JSON.stringify(result).match(/(?:\/[^"]+\.xcodeproj)/i);
  return candidate?.[0];
}

function findWorkspaceIdentifier(result, fallback) {
  return result?.workspaceIdentifier ?? result?.identifier ?? fallback;
}

function previewSource(letter) {
  return `import SwiftUI

struct ContentView: View {
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
    ContentView()
}
`;
}

let connected = false;
try {
  await client.connect(transport);
  connected = true;

  const { tools } = await client.listTools();
  results.tools = tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema }));

  const requiredTools = ["XcodeNewProject", "XcodeOpenWorkspace", "RenderPreview"];
  const missingTools = requiredTools.filter((name) => !tools.some((tool) => tool.name === name));
  if (missingTools.length > 0) {
    throw new Error(`Required Xcode MCP tools are missing: ${missingTools.join(", ")}`);
  }

  const newProject = await call("XcodeNewProject", {
    templateIdentifier: "com.apple.dt.unit.multiPlatform.app",
    productName: "HeadlessPreviewPOC",
    destinationPath: projectParent,
    organizationIdentifier: "dev.codex.previewpoc",
    options: {
      languageChoice: "Swift",
      storageType: "None",
      hostInCloudKit: "false",
      testingSystem: "None",
    },
  });

  const projectPath = findProjectPath(newProject);
  if (!projectPath) throw new Error(`XcodeNewProject did not return a project path: ${JSON.stringify(newProject)}`);

  const projectDirectory = path.dirname(projectPath);
  const sourceFile = path.join(projectDirectory, "HeadlessPreviewPOC", "ContentView.swift");
  await writeFile(sourceFile, previewSource("A"), "utf8");

  const openedWorkspace = await call("XcodeOpenWorkspace", { path: projectPath });
  const workspaceIdentifier = findWorkspaceIdentifier(openedWorkspace, projectPath);

  if (tools.some((tool) => tool.name === "BuildProject")) {
    await call("BuildProject", { workspaceIdentifier });
  }

  const sourceFilePath = "HeadlessPreviewPOC/ContentView.swift";
  const firstPreview = await call("RenderPreview", {
    workspaceIdentifier,
    sourceFilePath,
    timeout: 180,
  });
  const firstSnapshot = findSnapshotPath(firstPreview);
  if (!firstSnapshot) throw new Error(`First RenderPreview did not return a PNG path: ${JSON.stringify(firstPreview)}`);
  await copyFile(firstSnapshot, path.join(outputDirectory, "preview-A.png"));

  await writeFile(sourceFile, previewSource("B"), "utf8");
  const secondPreview = await call("RenderPreview", {
    workspaceIdentifier,
    sourceFilePath,
    timeout: 180,
  });
  const secondSnapshot = findSnapshotPath(secondPreview);
  if (!secondSnapshot) throw new Error(`Second RenderPreview did not return a PNG path: ${JSON.stringify(secondPreview)}`);
  await copyFile(secondSnapshot, path.join(outputDirectory, "preview-B.png"));

  const firstBytes = await readFile(path.join(outputDirectory, "preview-A.png"));
  const secondBytes = await readFile(path.join(outputDirectory, "preview-B.png"));
  const changed = !firstBytes.equals(secondBytes);
  if (!changed) throw new Error("The A and B preview PNG files are identical.");

  await writeFile(
    reportPath,
    [
      "# Xcode headless SwiftUI preview proof",
      "",
      "✅ `xcrun mcp-server` accepted the MCP client.",
      "",
      "✅ Xcode created and opened a temporary SwiftUI project without the Xcode UI.",
      "",
      "✅ `RenderPreview` produced `preview-A.png` and `preview-B.png`.",
      "",
      "✅ The two PNG files differ after changing the SwiftUI source from A to B.",
      "",
    ].join("\n"),
    "utf8",
  );
} catch (error) {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  results.error = message;
  await writeFile(
    reportPath,
    `# Xcode headless SwiftUI preview proof\n\n❌ The proof did not complete.\n\n\`\`\`text\n${message}\n\`\`\`\n`,
    "utf8",
  );
  process.exitCode = 1;
} finally {
  await writeFile(toolLogPath, JSON.stringify(results, null, 2), "utf8");
  if (connected) await client.close();
}
