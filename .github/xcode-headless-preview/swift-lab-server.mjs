import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { copyFile, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

const port = Number(process.env.SWIFT_LAB_PORT ?? 8080);
const token = process.env.SWIFT_LAB_TOKEN;
const projectPath = path.resolve(process.env.PREVIEW_PROJECT_PATH ?? "");
const sourceRoot = path.resolve(process.env.PREVIEW_SOURCE_ROOT ?? "");
const publicRoot = path.resolve(new URL("./swift-lab-public", import.meta.url).pathname);
const previewRoot = path.resolve(process.env.SWIFT_LAB_OUTPUT ?? "swift-lab-output");
const repositoryRoot = process.env.GITHUB_WORKSPACE ? path.resolve(process.env.GITHUB_WORKSPACE) : null;
const exec = promisify(execFile);

if (!token || !projectPath || !sourceRoot) {
  throw new Error("SWIFT_LAB_TOKEN, PREVIEW_PROJECT_PATH, and PREVIEW_SOURCE_ROOT are required.");
}

await mkdir(previewRoot, { recursive: true });

const transport = new StdioClientTransport({
  command: "xcrun",
  args: ["mcpbridge"],
  env: { ...process.env },
  stderr: "pipe",
});
transport.stderr?.on("data", (chunk) => process.stderr.write(chunk));

const client = new Client({ name: "swift-lab-live", version: "1.0.0" });
await client.connect(transport, { timeout: 180_000 });

const rawCall = async (name, args, timeout = 90_000) => {
  const raw = await client.request(
    { method: "tools/call", params: { name, arguments: args } },
    CompatibilityCallToolResultSchema,
    { timeout, resetTimeoutOnProgress: true },
  );
  const text = raw?.content?.filter((item) => item.type === "text").map((item) => item.text).join("\n");
  let decoded = raw?.structuredContent ?? raw;
  if (!raw?.structuredContent && text) {
    try { decoded = JSON.parse(text); } catch { decoded = { text }; }
  }
  if (raw?.isError) throw new Error(decoded?.text ?? JSON.stringify(decoded));
  return decoded;
};

const opened = await rawCall("XcodeOpenWorkspace", { path: projectPath }, 60_000);
const workspaceIdentifier = opened.workspaceIdentifier ?? projectPath;
let queue = Promise.resolve();
let latest = null;

function safeName(value) {
  const name = String(value ?? "");
  if (!/^[A-Za-z][A-Za-z0-9_-]*\.swift$/.test(name)) throw new Error("اسم الملف يجب أن ينتهي بـ .swift");
  return name;
}

function sourceFilePath(name) {
  return `PreviewLab/${safeName(name)}`;
}

async function bodyJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 1_000_000) throw new Error("الملف أكبر من الحد المسموح");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
}

function json(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  response.end(body);
}

async function listFiles() {
  return (await readdir(sourceRoot)).filter((name) => name.endsWith(".swift")).sort();
}

function findSnapshotPath(result) {
  if (typeof result?.previewSnapshotPath === "string") return result.previewSnapshotPath;
  return JSON.stringify(result).match(/(?:\/[^\"]+\.png)/i)?.[0];
}

async function renderFile(name, content) {
  const started = performance.now();
  const fileName = safeName(name);
  await rawCall("XcodeWrite", { workspaceIdentifier, filePath: sourceFilePath(fileName), content }, 60_000);
  const rendered = await rawCall("RenderPreview", {
    workspaceIdentifier,
    sourceFilePath: sourceFilePath(fileName),
    previewDefinitionIndexInFile: 0,
    timeout: 180,
  }, 220_000);
  const snapshotPath = findSnapshotPath(rendered);
  if (!snapshotPath) throw new Error("لم يرجع Xcode صورة Preview");
  const version = Date.now();
  const destination = path.join(previewRoot, `${version}.png`);
  await copyFile(snapshotPath, destination);
  if (repositoryRoot) {
    await exec("git", ["add", "--", sourceRoot], { cwd: repositoryRoot });
    const staged = await exec("git", ["diff", "--cached", "--quiet"], { cwd: repositoryRoot }).then(() => false, () => true);
    if (staged) {
      await exec("git", ["commit", "-m", `Swift Lab autosave: ${fileName} [skip ci]`], { cwd: repositoryRoot });
      await exec("git", ["push", "origin", "HEAD:main"], { cwd: repositoryRoot });
    }
  }
  latest = { path: destination, version, fileName, elapsedMs: Math.round(performance.now() - started) };
  return latest;
}

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);
    const prefix = `/${token}`;
    if (!url.pathname.startsWith(prefix)) return json(response, 404, { error: "Not found" });
    const route = url.pathname.slice(prefix.length) || "/";

    if (request.method === "GET" && route === "/") {
      const html = await readFile(path.join(publicRoot, "index.html"));
      response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
      return response.end(html);
    }
    if (request.method === "GET" && route === "/api/state") {
      return json(response, 200, { files: await listFiles(), latest: latest && { ...latest, path: undefined } });
    }
    if (request.method === "GET" && route === "/api/file") {
      const name = safeName(url.searchParams.get("name"));
      return json(response, 200, { name, content: await readFile(path.join(sourceRoot, name), "utf8") });
    }
    if (request.method === "POST" && route === "/api/render") {
      const body = await bodyJson(request);
      const task = queue.then(() => renderFile(body.name, String(body.content ?? "")));
      queue = task.catch(() => {});
      const result = await task;
      return json(response, 200, { ok: true, elapsedMs: result.elapsedMs, version: result.version });
    }
    if (request.method === "GET" && route === "/preview.png" && latest) {
      const image = await readFile(latest.path);
      response.writeHead(200, { "content-type": "image/png", "cache-control": "no-store" });
      return response.end(image);
    }
    if (request.method === "GET" && route === "/health") return json(response, 200, { ok: true });
    return json(response, 404, { error: "Not found" });
  } catch (error) {
    return json(response, 400, { error: error instanceof Error ? error.message : String(error) });
  }
});

server.listen(port, "127.0.0.1", () => console.log(`Swift Lab listening on http://127.0.0.1:${port}/${token}/`));

const shutdown = async () => {
  server.close();
  await client.close().catch(() => {});
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
