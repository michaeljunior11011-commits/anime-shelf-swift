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
const frames = [];
const sendMetrics = [];
let latestFrame;
let activeSessionID;
let ignoredForeignPackets = 0;
let helperSummary;
let completed = false;

function selectedSessionID() {
  if (activeSessionID) return activeSessionID;
  const counts = new Map();
  for (const frame of frames) counts.set(frame.sessionID, (counts.get(frame.sessionID) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
}

const page = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Preview Wire</title>
  <style>
    :root{color-scheme:dark;--ink:#ece9df;--muted:#77756e;--live:#c6ff37;--line:#292925}
    *{box-sizing:border-box}html,body{margin:0;min-height:100%;background:#080808;color:var(--ink)}
    body{font-family:"IBM Plex Mono","Courier New",monospace;overflow:hidden}
    main{height:100vh;display:grid;grid-template-rows:auto 1fr auto;padding:18px 22px 16px;gap:14px}
    header,footer{display:flex;align-items:center;justify-content:space-between;font-size:11px;letter-spacing:.16em;text-transform:uppercase}
    .state{display:flex;align-items:center;gap:9px;color:var(--live)}.dot{width:7px;height:7px;border-radius:50%;background:currentColor;box-shadow:0 0 18px currentColor}
    .stage{min-height:0;display:grid;place-items:center;border:1px solid var(--line);background:#0b0b0a;overflow:hidden}
    #preview{display:block;max-width:100%;max-height:100%;width:auto;height:auto;object-fit:contain}
    .metrics{display:flex;gap:24px;color:var(--muted)}.metrics b{color:var(--ink);font-weight:500}
  </style>
</head>
<body><main>
  <header><span>Preview Wire / XCPreviewAgent</span><span class="state"><i class="dot"></i>live</span></header>
  <section class="stage"><img id="preview" src="/stream.mjpeg" alt="Live Xcode Preview"></section>
  <footer class="metrics"><span>TARGET <b id="target">–</b></span><span>FPS <b id="fps">0.0</b></span><span>CAP <b id="capture">0 ms</b></span><span>JPEG <b id="encode">0 ms</b></span><span>E2E <b id="e2e">0 ms</b></span></footer>
</main><script>
  async function refresh(){try{const s=await fetch('/stats',{cache:'no-store'}).then(r=>r.json());const p=s.phases?.at(-1);target.textContent=p?.targetFPS||'–';fps.textContent=(p?.actualFPS||0).toFixed(1);capture.textContent=(p?.captureMs?.average||0).toFixed(0)+' ms';encode.textContent=(p?.encodeMs?.average||0).toFixed(0)+' ms';e2e.textContent=(p?.endToEndMs?.average||0).toFixed(0)+' ms'}catch{}}
  setInterval(refresh,500);refresh();
</script></body></html>`;

function percentile(values, fraction) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * fraction))];
}

function aggregate(values) {
  return {
    average: values.length ? values.reduce((a, b) => a + b, 0) / values.length : 0,
    p50: percentile(values, 0.5), p95: percentile(values, 0.95),
    min: values.length ? Math.min(...values) : 0,
    max: values.length ? Math.max(...values) : 0,
  };
}

function summary() {
  const sessionID = selectedSessionID();
  const selectedFrames = frames.filter((item) => item.sessionID === sessionID);
  const selectedSends = sendMetrics.filter((item) => item.sessionID === sessionID);
  const phaseDefinitions = helperSummary?.phaseCaptureSummary ?? [];
  const phaseIndexes = [...new Set([...phaseDefinitions.map((p) => p.phaseIndex), ...selectedFrames.map((f) => f.phaseIndex)])].sort((a, b) => a - b);
  const phases = phaseIndexes.map((phaseIndex) => {
    const definition = phaseDefinitions.find((item) => item.phaseIndex === phaseIndex) ?? {};
    const phaseFrames = selectedFrames.filter((item) => item.phaseIndex === phaseIndex);
    const phaseSends = selectedSends.filter((item) => item.phaseIndex === phaseIndex);
    const durationSeconds = definition.durationSeconds ?? phaseFrames.at(-1)?.phaseElapsedSeconds ?? 0;
    const pipelinePhase = helperSummary?.pipelineSummary?.phases?.find((item) => item.phaseIndex === phaseIndex) ?? {};
    return {
      phaseIndex,
      targetFPS: definition.targetFPS ?? phaseFrames[0]?.targetFPS,
      durationSeconds,
      captureAttempts: definition.captureAttempts ?? 0,
      captureAllAverageMs: definition.captureAverageMs ?? 0,
      receivedFrames: phaseFrames.length,
      uniqueFrames: new Set(phaseFrames.map((item) => item.frameHash)).size,
      actualFPS: durationSeconds ? phaseFrames.length / durationSeconds : 0,
      replacedPendingFrames: pipelinePhase.replacedPendingFrames ?? 0,
      encodeFailures: pipelinePhase.encodeFailures ?? 0,
      sendFailures: pipelinePhase.sendFailures ?? 0,
      captureMs: aggregate(phaseFrames.map((item) => item.captureMs)),
      encodeMs: aggregate(phaseFrames.map((item) => item.encodeMs)),
      jpegBytes: aggregate(phaseFrames.map((item) => item.jpegBytes)),
      networkSendMs: aggregate(phaseSends.map((item) => item.networkSendMs)),
      endToEndMs: aggregate(phaseSends.map((item) => item.endToEndSendMs)),
      totalJPEGBytes: phaseFrames.reduce((sum, item) => sum + item.jpegBytes, 0),
    };
  });
  return { complete: completed, activeSessionID: sessionID, ignoredForeignPackets: frames.length - selectedFrames.length, frameCount: selectedFrames.length, phases, helperSummary };
}

async function finish(header) {
  if (completed) return;
  activeSessionID = header.sessionID;
  helperSummary = header;
  completed = true;
  await writeFile(path.join(outputDirectory, "receiver-stats.json"), JSON.stringify(summary(), null, 2), "utf8");
  await writeFile(path.join(outputDirectory, "frame-metrics.json"), JSON.stringify(frames, null, 2), "utf8");
  await writeFile(path.join(outputDirectory, "network-send-metrics.json"), JSON.stringify(sendMetrics, null, 2), "utf8");
  await writeFile(path.join(outputDirectory, "viewer.html"), page, "utf8");
}

function publishFrame(header, jpeg) {
  const receivedEpochMs = Date.now();
  const enriched = {
    ...header,
    receivedEpochMs,
  };
  frames.push(enriched);
  latestFrame = jpeg;
  const prefix = Buffer.from(`--preview-frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n`);
  for (const response of clients) {
    try { response.write(prefix); response.write(jpeg); response.write("\r\n"); } catch { clients.delete(response); }
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
      const jpeg = Buffer.from(buffer.subarray(headerEnd + 4, packetLength));
      buffer = buffer.subarray(packetLength);
      if (header.type === "frame") publishFrame(header, jpeg);
      else if (header.type === "sendMetric") sendMetrics.push(header);
      else if (header.type === "end" && header.phaseCaptureSummary?.length === 3) void finish(header);
    }
  });
}

const tcpServer = createTCPServer(parseConnection);
const httpServer = createHTTPServer((request, response) => {
  if (request.url === "/" || request.url === "/index.html") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }); response.end(page); return;
  }
  if (request.url === "/health") { response.writeHead(200, { "content-type": "application/json" }); response.end(JSON.stringify({ ok: true, tcpPort, httpPort })); return; }
  if (request.url === "/stats") { response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }); response.end(JSON.stringify(summary())); return; }
  if (request.url === "/stream.mjpeg") {
    response.writeHead(200, { "content-type": "multipart/x-mixed-replace; boundary=preview-frame", "cache-control": "no-store", connection: "close" });
    clients.add(response); request.on("close", () => clients.delete(response));
    if (latestFrame) { response.write(`--preview-frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${latestFrame.length}\r\n\r\n`); response.write(latestFrame); response.write("\r\n"); }
    return;
  }
  response.writeHead(404).end();
});

await new Promise((resolve, reject) => tcpServer.listen(tcpPort, "0.0.0.0", resolve).once("error", reject));
await new Promise((resolve, reject) => httpServer.listen(httpPort, "127.0.0.1", resolve).once("error", reject));
console.log(JSON.stringify({ ready: true, tcpPort, httpPort }));

for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => { tcpServer.close(); httpServer.close(() => process.exit(0)); });
