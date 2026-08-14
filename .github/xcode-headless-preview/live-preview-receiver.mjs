import { spawn } from "node:child_process";
import { createServer as createHTTPServer } from "node:http";
import { createServer as createTCPServer } from "node:net";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const outputDirectory = path.resolve(process.argv[2] ?? "live-preview-stream-output");
const tcpPort = Number(process.env.PREVIEW_STREAM_TCP_PORT ?? 8787);
const httpPort = Number(process.env.PREVIEW_STREAM_HTTP_PORT ?? 8080);
await mkdir(outputDirectory, { recursive: true });

const clients = new Set();
const recordedFrames = [];
const frameMetrics = [];
let latestFrame;
let firstFrameAt;
let lastFrameAt;
let completed = false;
let helperSummary;
let videoResult;
let activeSessionID;
let ignoredForeignFrames = 0;

const page = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Preview Wire</title>
  <style>
    :root { color-scheme: dark; --ink:#ece9df; --muted:#77756e; --live:#c6ff37; --line:#292925; }
    * { box-sizing: border-box; }
    html, body { margin:0; min-height:100%; background:#080808; color:var(--ink); }
    body { font-family: "IBM Plex Mono", "Courier New", monospace; overflow:hidden; }
    main { height:100vh; display:grid; grid-template-rows:auto 1fr auto; padding:18px 22px 16px; gap:14px; }
    header, footer { display:flex; align-items:center; justify-content:space-between; font-size:11px; letter-spacing:.16em; text-transform:uppercase; }
    .brand { font-weight:700; }
    .state { display:flex; align-items:center; gap:9px; color:var(--live); }
    .dot { width:7px; height:7px; border-radius:50%; background:currentColor; box-shadow:0 0 18px currentColor; }
    .stage { min-height:0; display:grid; place-items:center; border:1px solid var(--line); background:radial-gradient(circle at 50% 45%, #171715, #0b0b0a 58%, #070707); overflow:hidden; position:relative; }
    .stage::after { content:""; position:absolute; inset:0; pointer-events:none; opacity:.12; background:repeating-linear-gradient(0deg, transparent 0 3px, #fff 4px); mix-blend-mode:soft-light; }
    #preview { display:block; max-width:100%; max-height:100%; width:auto; height:auto; object-fit:contain; }
    .metrics { display:flex; gap:26px; color:var(--muted); }
    .metrics b { color:var(--ink); font-weight:500; }
    @media (max-width:640px) { main{padding:12px;gap:10px}.metrics{gap:12px;font-size:9px} }
  </style>
</head>
<body>
  <main>
    <header><span class="brand">Preview Wire / XCPreviewAgent</span><span class="state"><i class="dot"></i>live</span></header>
    <section class="stage"><img id="preview" src="/stream.mjpeg" alt="Live Xcode Preview"></section>
    <footer class="metrics">
      <span>FPS <b id="fps">0.0</b></span>
      <span>CAP <b id="capture">0.0 ms</b></span>
      <span>JPEG <b id="encode">0.0 ms</b></span>
      <span>FRAME <b id="bytes">0 KB</b></span>
    </footer>
  </main>
  <script>
    async function refresh() {
      try {
        const s = await fetch('/stats', { cache: 'no-store' }).then(r => r.json());
        fps.textContent = (s.liveFPS || 0).toFixed(1);
        capture.textContent = (s.latest?.captureMs || 0).toFixed(1) + ' ms';
        encode.textContent = (s.latest?.encodeMs || 0).toFixed(1) + ' ms';
        bytes.textContent = ((s.latest?.jpegBytes || 0) / 1024).toFixed(0) + ' KB';
      } catch {}
    }
    setInterval(refresh, 500); refresh();
  </script>
</body>
</html>`;

function percentile(values, fraction) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * fraction))];
}

function summary() {
  const arrivalDurationSeconds = firstFrameAt && lastFrameAt ? Math.max(0.001, (lastFrameAt - firstFrameAt) / 1000) : 0;
  const durationSeconds = helperSummary?.durationSeconds ?? frameMetrics.at(-1)?.elapsedSeconds ?? arrivalDurationSeconds;
  const capture = frameMetrics.map((item) => item.captureMs);
  const encode = frameMetrics.map((item) => item.encodeMs);
  const sizes = frameMetrics.map((item) => item.jpegBytes);
  const summarize = (values) => ({
    average: values.length ? values.reduce((a, b) => a + b, 0) / values.length : 0,
    p50: percentile(values, 0.5),
    p95: percentile(values, 0.95),
    min: values.length ? Math.min(...values) : 0,
    max: values.length ? Math.max(...values) : 0,
  });
  return {
    complete: completed,
    activeSessionID,
    ignoredForeignFrames,
    frameCount: frameMetrics.length,
    uniqueFrameCount: new Set(frameMetrics.map((item) => item.frameHash)).size,
    durationSeconds,
    arrivalDurationSeconds,
    liveFPS: durationSeconds ? frameMetrics.length / durationSeconds : 0,
    latest: frameMetrics.at(-1),
    captureMs: summarize(capture),
    encodeMs: summarize(encode),
    jpegBytes: summarize(sizes),
    totalJPEGBytes: sizes.reduce((a, b) => a + b, 0),
    helperSummary,
    videoResult,
  };
}

async function createProofVideo() {
  if (recordedFrames.length === 0) return { ok: false, error: "No received frames." };
  const stats = summary();
  const sourceFPS = Math.max(1, Math.min(10, stats.frameCount / Math.max(1, stats.durationSeconds)));
  const outputPath = path.join(outputDirectory, "live-preview-30s.mp4");
  return await new Promise((resolve) => {
    const child = spawn("ffmpeg", [
      "-y", "-f", "image2pipe", "-framerate", sourceFPS.toFixed(4), "-vcodec", "mjpeg", "-i", "pipe:0",
      "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-movflags", "+faststart", outputPath,
    ], { stdio: ["pipe", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => resolve({ ok: false, error: error.message }));
    child.on("close", (code) => resolve({ ok: code === 0, code, sourceFPS, outputPath, stderr: stderr.slice(-4000) }));
    for (const frame of recordedFrames) child.stdin.write(frame);
    child.stdin.end();
  });
}

async function finish(header) {
  if (completed) return;
  completed = true;
  helperSummary = header;
  videoResult = await createProofVideo();
  await writeFile(path.join(outputDirectory, "receiver-stats.json"), JSON.stringify(summary(), null, 2), "utf8");
  await writeFile(path.join(outputDirectory, "frame-metrics.json"), JSON.stringify(frameMetrics, null, 2), "utf8");
  await writeFile(path.join(outputDirectory, "viewer.html"), page, "utf8");
}

function publishFrame(header, jpeg) {
  activeSessionID ??= header.sessionID;
  if (header.sessionID !== activeSessionID) {
    ignoredForeignFrames += 1;
    return;
  }
  const now = performance.now();
  firstFrameAt ??= now;
  lastFrameAt = now;
  latestFrame = jpeg;
  recordedFrames.push(jpeg);
  frameMetrics.push(header);
  const prefix = Buffer.from(`--preview-frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n`);
  const suffix = Buffer.from("\r\n");
  for (const response of clients) {
    try { response.write(prefix); response.write(jpeg); response.write(suffix); } catch { clients.delete(response); }
  }
}

function parseConnection(socket) {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 8) {
      const headerLength = buffer.readUInt32BE(0);
      if (headerLength > 1024 * 1024 || buffer.length < 4 + headerLength + 4) return;
      const headerEnd = 4 + headerLength;
      const jpegLength = buffer.readUInt32BE(headerEnd);
      const packetLength = headerEnd + 4 + jpegLength;
      if (jpegLength > 20 * 1024 * 1024 || buffer.length < packetLength) return;
      const header = JSON.parse(buffer.subarray(4, headerEnd).toString("utf8"));
      const jpeg = buffer.subarray(headerEnd + 4, packetLength);
      buffer = buffer.subarray(packetLength);
      if (header.type === "frame") publishFrame(header, Buffer.from(jpeg));
      if (header.type === "end" && header.sessionID === activeSessionID) void finish(header);
    }
  });
}

const tcpServer = createTCPServer(parseConnection);
const httpServer = createHTTPServer((request, response) => {
  if (request.url === "/" || request.url === "/index.html") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    response.end(page);
    return;
  }
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true, tcpPort, httpPort }));
    return;
  }
  if (request.url === "/stats") {
    response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    response.end(JSON.stringify(summary()));
    return;
  }
  if (request.url === "/stream.mjpeg") {
    response.writeHead(200, {
      "content-type": "multipart/x-mixed-replace; boundary=preview-frame",
      "cache-control": "no-store, no-cache, must-revalidate",
      connection: "close",
    });
    clients.add(response);
    request.on("close", () => clients.delete(response));
    if (latestFrame) {
      response.write(`--preview-frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${latestFrame.length}\r\n\r\n`);
      response.write(latestFrame);
      response.write("\r\n");
    }
    return;
  }
  response.writeHead(404).end();
});

await new Promise((resolve, reject) => tcpServer.listen(tcpPort, "0.0.0.0", resolve).once("error", reject));
await new Promise((resolve, reject) => httpServer.listen(httpPort, "127.0.0.1", resolve).once("error", reject));
console.log(JSON.stringify({ ready: true, tcpPort, httpPort }));

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, async () => {
    if (!completed && frameMetrics.length) await finish({ type: "end", reason: signal });
    tcpServer.close();
    httpServer.close(() => process.exit(0));
  });
}
